import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation
import Observation

/// 2× and 4× upscaling with Real-ESRGAN x4plus (BSD-3-Clause), using john-rocky's Core ML
/// conversion: 512×512 tiles in, 2048×2048 out, run on the GPU and Neural Engine. It's
/// downloaded once (67 MB), checked against a known hash, and compiled on this Mac. Each
/// upscaled picture is saved as a new picture next to the original, recording how it was made.
@MainActor
@Observable
final class Upscaler {
    enum Status: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let record: GenerationRecord
        let scale: Int
    }

    static let repo = "mlboydaisuke/Real-ESRGAN-x4-CoreML"
    static let packageName = "RealESRGAN_x4.mlpackage"
    /// SHA-256 of the package's model.mlmodel when this was written: a changed upload is
    /// refused instead of run.
    static let modelSHA256 = "6107dc417de87bf974e5b225a2632e2c78f2849265dc897981f482e922050ec9"
    static let approxMB = 67
    nonisolated static let modelName = "Real-ESRGAN x4plus"
    /// The longest side an upscaled picture may have: a 2048 px picture at 4× is 8192 px
    /// (256 MB as pixels), and anything larger risks running a 16 GB Mac out of memory.
    static let maxOutputSide = 8192

    nonisolated static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "CoreMLImageGen/Upscalers", directoryHint: .isDirectory)
    nonisolated static var compiledURL: URL { folder.appending(path: "RealESRGAN_x4.mlmodelc") }

    private(set) var status: Status = FileManager.default.fileExists(atPath: Upscaler.compiledURL.path)
        ? .installed : .notInstalled
    /// Waiting jobs; `running` is the one in progress.
    private(set) var jobs: [Job] = []
    private(set) var running: Job?
    /// How far through the running job, 0–1.
    private(set) var progress = 0.0
    /// The newest upscaled picture, so My Pictures and Create can show it.
    private(set) var lastRecord: GenerationRecord?
    var lastError: String?

    private var runner: Task<Void, Never>?
    private var engine: UpscaleEngine?
    private let cancelFlag = CancelFlag()

    var isBusy: Bool { runner != nil }

    /// Whether `record` can be upscaled by `scale` without going past `maxOutputSide`.
    static func canUpscale(_ size: CGSize?, by scale: Int) -> Bool {
        guard let size else { return false }
        return Int(max(size.width, size.height)) * scale <= maxOutputSide
    }

    /// Queues pictures to upscale; downloads the model first if needed.
    func upscale(_ records: [GenerationRecord], scale: Int) {
        jobs += records.map { Job(record: $0, scale: scale) }
        lastError = nil
        if runner == nil { runner = Task { await run() } }
    }

    /// Stops the running job and drops the waiting ones.
    func cancelAll() {
        jobs.removeAll()
        cancelFlag.set(true)
    }

    private func run() async {
        defer {
            runner = nil
            running = nil
            engine = nil  // frees the model (~500 MB) once the queue is done
        }
        if status != .installed {
            do {
                try await install()
            } catch {
                status = .failed(error.localizedDescription)
                lastError = "Couldn't get the upscaler: \(error.localizedDescription)"
                jobs.removeAll()
                return
            }
        }
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            running = job
            progress = 0
            cancelFlag.set(false)
            do {
                lastRecord = try await perform(job)
            } catch is CancellationError {
                continue
            } catch {
                lastError = "Couldn't upscale \(job.record.fileName): \(error.localizedDescription)"
            }
        }
    }

    private func perform(_ job: Job) async throws -> GenerationRecord {
        let source = ImageSaver.folder.appending(path: job.record.fileName)
        if engine == nil {
            let url = Self.compiledURL
            let loadStart = Date()
            engine = try await Task.detached { try UpscaleEngine(modelURL: url) }.value
            #if DEBUG
            print("[upscaler] model loaded in \(String(format: "%.1f", Date().timeIntervalSince(loadStart))) s")
            #endif
        }
        guard let engine else { throw CancellationError() }
        let flag = cancelFlag
        let start = Date()
        let image = try await Task.detached(priority: .userInitiated) { () throws -> CGImage in
            guard let input = StartImages.load(source.path) else {
                throw RuntimeError("The picture's file couldn't be read.")
            }
            return try engine.upscale(input, scale: job.scale, isCancelled: { flag.isSet }) { fraction in
                Task { @MainActor [weak self] in self?.progress = fraction }
            }
        }.value
        let seconds = Date().timeIntervalSince(start)
        // A 4096 px PNG takes a few seconds to compress: off the main thread.
        let record = job.record, scale = job.scale
        let saveStart = Date()
        let saved = try await Task.detached(priority: .userInitiated) {
            try ImageSaver.saveUpscaled(image, from: record, scale: scale, seconds: seconds)
        }.value
        #if DEBUG
        print("[upscaler] \(scale)× in \(String(format: "%.1f", seconds)) s, saved in \(String(format: "%.1f", Date().timeIntervalSince(saveStart))) s")
        #endif
        return saved
    }

    /// Downloads the Core ML package, checks it, and compiles it into `compiledURL`.
    func install() async throws {
        status = .downloading(0)
        let fm = FileManager.default
        let staging = Self.folder.appending(path: "download-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: staging) }
        let files = try await HuggingFace.listFiles(repo: Self.repo, prefix: Self.packageName + "/")
        guard !files.isEmpty else { throw RuntimeError("\(Self.repo) has no \(Self.packageName).") }
        try await HuggingFace.download(repo: Self.repo, files: files, into: staging) { [weak self] fraction in
            self?.status = .downloading(fraction)
        }
        let package = staging.appending(path: Self.packageName)
        let weights = package.appending(path: "Data/com.apple.CoreML/model.mlmodel")
        let hash = try await Task.detached {
            SHA256.hash(data: try Data(contentsOf: weights, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
        }.value
        guard hash == Self.modelSHA256 else {
            throw RuntimeError("The downloaded upscaler doesn't match the expected file (SHA-256 \(hash.prefix(12))…), so it wasn't used.")
        }
        let compiled = try await MLModel.compileModel(at: package)
        try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? fm.removeItem(at: Self.compiledURL)
        try fm.moveItem(at: compiled, to: Self.compiledURL)
        status = .installed
    }

    /// Removes the compiled model; the next upscale downloads it again.
    func delete() {
        guard !isBusy else { return }
        try? FileManager.default.removeItem(at: Self.compiledURL)
        status = .notInstalled
    }
}

/// Runs the model over a picture in overlapping 512 px tiles. Each tile's outer `pad` pixels
/// (where the model sees less context) are dropped, except at the picture's own edges, so
/// there are no seams. Not tied to an actor: it runs on a background task.
final class UpscaleEngine: @unchecked Sendable {
    static let tile = 512
    static let factor = 4
    static let pad = 32

    private let model: MLModel
    /// No colour management: the model works on sRGB values, and they pass through unchanged.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .cacheIntermediates: false])
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init(modelURL: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .all  // what the conversion was verified with
        model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    func upscale(_ image: CGImage, scale: Int, isCancelled: () -> Bool,
                 progress: (Double) -> Void) throws -> CGImage {
        let (tile, f) = (Self.tile, Self.factor)
        let (w, h) = (image.width, image.height)
        let xs = Self.origins(w), ys = Self.origins(h)
        guard let out = CGContext(data: nil, width: w * f, height: h * f, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw RuntimeError("Not enough memory for a \(w * f) × \(h * f) picture.") }
        // Edge pixels repeat outward, so a tile hanging over the edge of a small picture sees
        // a plausible border instead of black.
        let source = CIImage(cgImage: image).clampedToExtent()
        var done = 0
        for (yi, oy) in ys.enumerated() {
            for (xi, ox) in xs.enumerated() {
                if isCancelled() { throw CancellationError() }
                // Core Image counts y from the bottom; the tiles are laid out from the top.
                let tileRect = CGRect(x: ox, y: h - oy - tile, width: tile, height: tile)
                guard let tileImage = context.createCGImage(source, from: tileRect, format: .RGBA8, colorSpace: sRGB)
                else { throw RuntimeError("Couldn't cut a tile from the picture.") }
                let input = try MLFeatureValue(cgImage: tileImage, pixelsWide: tile, pixelsHigh: tile,
                                               pixelFormatType: kCVPixelFormatType_32BGRA, options: nil)
                let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input": input]))
                guard let buffer = result.featureValue(for: "activation_out")?.imageBufferValue else {
                    throw RuntimeError("The upscaler returned no image.")
                }
                let (x0, x1) = Self.span(xi, of: xs, length: w)
                let (y0, y1) = Self.span(yi, of: ys, length: h)
                // The kept part of this tile, in the 2048 px output tile (bottom-left origin)…
                let local = CGRect(x: (x0 - ox) * f, y: (oy + tile - y1) * f, width: (x1 - x0) * f, height: (y1 - y0) * f)
                guard let piece = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: local,
                                                        format: .RGBA8, colorSpace: sRGB)
                else { throw RuntimeError("Couldn't read the upscaled tile.") }
                // …and where it goes in the whole picture (also bottom-left origin).
                out.draw(piece, in: CGRect(x: x0 * f, y: (h - y1) * f, width: (x1 - x0) * f, height: (y1 - y0) * f))
                done += 1
                progress(Double(done) / Double(xs.count * ys.count))
            }
        }
        guard let upscaled = out.makeImage() else { throw RuntimeError("Couldn't finish the upscaled picture.") }
        guard scale != f else { return upscaled }
        // 2×: the 4× result scaled down with Lanczos, sharper than a native 2× model would be.
        let factor = Double(scale) / Double(f)
        let scaled = CIImage(cgImage: upscaled).applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1.0,
        ])
        let rect = CGRect(x: 0, y: 0, width: w * scale, height: h * scale)
        guard let result = context.createCGImage(scaled, from: rect, format: .RGBA8, colorSpace: sRGB) else {
            throw RuntimeError("Couldn't scale the picture to \(scale)×.")
        }
        return result
    }

    /// Tile starts along one side: a step of `tile - 2 * pad`, with the last tile flush with
    /// the far edge. A side shorter than a tile gets one tile (the overhang is padding).
    static func origins(_ length: Int) -> [Int] {
        guard length > tile else { return [0] }
        var result: [Int] = []
        var origin = 0
        while origin + tile < length {
            result.append(origin)
            origin += tile - 2 * pad
        }
        result.append(length - tile)
        return result
    }

    /// The part of the side that tile `i` fills: from where the previous one stopped to `pad`
    /// before its own far edge (or the picture's edge for the last one).
    static func span(_ i: Int, of origins: [Int], length: Int) -> (Int, Int) {
        func end(_ j: Int) -> Int { j == origins.count - 1 ? length : origins[j] + tile - pad }
        return (i == 0 ? 0 : end(i - 1), end(i))
    }
}
