import CoreGraphics
import Foundation
import ImageIO

/// Runs mflux models (Z-Image, FLUX.2, Qwen-Image…) in a separate Python process,
/// mlx_worker.py, over JSON lines. The model stays loaded in the worker between images;
/// unloading terminates the process, which is the surest way to free all of its memory.
final class MLXBackend: ImageBackend {
    let model: InstalledModel
    private var process: Process?
    private var input: FileHandle?
    private var reader: LineReader?
    /// LoRAs baked into the currently loaded weights; nil when nothing is loaded.
    private var loadedLoRAs: [LoRARef]?

    init(model: InstalledModel) {
        self.model = model
    }

    func load() throws {
        try load(for: GenerationRequest())
    }

    func load(for request: GenerationRequest) throws {
        guard MLXRuntime.isInstalled else {
            throw RuntimeError("Install the MLX runtime first (Models → MLX runtime).")
        }
        guard let family = model.mlxFamily else {
            throw RuntimeError("\(model.name) has no MLX model family in its model.json.")
        }
        if process?.isRunning != true { try startWorker() }
        let loras = request.loras ?? []
        try send([
            "op": "load",
            "family": family,
            "path": model.folder.path,
            "loras": loras.map { ["path": $0.source, "scale": $0.scale] },
            "float16": true,
        ])
        while true {
            let event = try nextEvent()
            switch event["event"] as? String {
            case "loaded":
                loadedLoRAs = loras
                return
            case "error":
                throw RuntimeError(event["message"] as? String ?? "MLX worker failed to load the model.")
            default:
                continue
            }
        }
    }

    /// mflux bakes LoRAs into the weights at load, so a different LoRA set needs a reload.
    func needsReload(for request: GenerationRequest) -> Bool {
        loadedLoRAs != (request.loras ?? [])
    }

    func generate(
        _ request: GenerationRequest,
        previewEvery: Int,
        onStep: (Int, Int, CGImage?) -> Bool
    ) throws -> CGImage? {
        if loadedLoRAs == nil || needsReload(for: request) { try load(for: request) }

        let size = (request.aspect ?? .square).size(base: model.resolution)
        let out = FileManager.default.temporaryDirectory.appending(path: "mlx-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let supportsNegative = model.defaults?.supportsNegativePrompt ?? true
        var startImage: [String: Any] = [:]
        if let path = request.startImage {
            // mflux's image_strength is the share of steps skipped (higher keeps more of
            // the image), the inverse of `change`.
            startImage = ["image_path": path, "image_strength": 1 - min(max(request.change ?? 0.6, 0.05), 1)]
        }
        try send(startImage.merging([
            "op": "generate",
            "prompt": request.prompt,
            "negative_prompt": supportsNegative ? request.negativePrompt : "",
            "seed": Int(request.seed),
            "steps": request.steps,
            "guidance": request.guidance,
            "width": size.width,
            "height": size.height,
            "out": out.path,
        ]) { a, _ in a })

        var cancelSent = false
        while true {
            let event = try nextEvent()
            switch event["event"] as? String {
            case "step":
                let step = event["step"] as? Int ?? 0
                let total = event["total"] as? Int ?? request.steps
                if !onStep(step, total, nil), !cancelSent, let pid = process?.processIdentifier {
                    kill(pid, SIGUSR1)  // the worker stops at its next step
                    cancelSent = true
                }
            case "done":
                // Decode now: CGImageSource is lazy, and `out` is deleted when we return.
                let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(out as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, options)
                else { throw BackendError.noImage }
                return image
            case "cancelled":
                throw CancellationError()
            case "error":
                throw RuntimeError(event["message"] as? String ?? "MLX generation failed.")
            default:
                continue
            }
        }
    }

    func unload() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        input = nil
        reader = nil
        loadedLoRAs = nil
    }

    deinit { unload() }

    // MARK: Worker process

    private func startWorker() throws {
        guard let script = MLXRuntime.workerScript else {
            throw RuntimeError("mlx_worker.py is missing from the app bundle.")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: MLXRuntime.logURL.path) {
            fm.createFile(atPath: MLXRuntime.logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: MLXRuntime.logURL)
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = MLXRuntime.python
        process.arguments = ["-I", "-u", script.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = log  // mflux logs and tracebacks, for debugging
        try process.run()

        self.process = process
        input = stdinPipe.fileHandleForWriting
        reader = LineReader(handle: stdoutPipe.fileHandleForReading)
        let ready = try nextEvent()
        guard ready["event"] as? String == "ready" else {
            throw RuntimeError("MLX worker didn't start. See \(MLXRuntime.logURL.path).")
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw RuntimeError("MLX worker isn't running.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func nextEvent() throws -> [String: Any] {
        guard let line = reader?.readLine() else {
            let status = process?.terminationStatus
            unload()
            // A worker killed for using too much memory exits with SIGKILL (status 9).
            throw RuntimeError("The MLX worker stopped\(status.map { " (status \($0))" } ?? ""), "
                               + "most likely out of memory. Try a smaller size or model. Log: \(MLXRuntime.logURL.path)")
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return [:]
        }
        return object
    }
}

/// Blocking line reader over a pipe; returns nil at end of file.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.availableData  // blocks until data or EOF
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
