import CoreGraphics
import Foundation
import ImageIO

/// Runs mflux models (Z-Image, FLUX.2, Qwen-Image…) in a separate Python process,
/// mlx_worker.py, over JSON lines. The model stays loaded in the worker between images;
/// unloading terminates the process, which is the surest way to free all of its memory.
final class MLXBackend: ImageBackend {
    let model: InstalledModel
    private let worker = MLXWorker()
    /// LoRAs baked into the currently loaded weights; nil when nothing is loaded.
    private var loadedLoRAs: [LoRARef]?
    /// Whether the loaded pipeline is the family's editing one (Edit with words).
    private var loadedForEditing = false
    /// Steps in the picture being made (0 when idle), to turn a preview setting into an interval.
    private let runningSteps = LockedInt()

    init(model: InstalledModel) {
        self.model = model
    }

    /// UserDefaults key for "Skip near-identical steps" in Settings.
    static let stepCacheKey = "mlxStepCache"
    /// Share of steps whose model output is reused (mflux's step_cache_ratio). mflux
    /// always computes the first and last 10% of steps and skips nothing below 10 steps.
    static let stepCacheRatio = 0.25

    func withSpeedSettings(_ request: GenerationRequest) -> GenerationRequest {
        var recorded = request
        recorded.stepCacheRatio = stepCacheRatio(for: request)
        return recorded
    }

    func stepCacheRatio(for request: GenerationRequest) -> Double? {
        guard MLXFamilies.family(id: model.mlxFamily)?.supportsStepCache == true,
              UserDefaults.standard.bool(forKey: Self.stepCacheKey),
              request.steps >= 10 else { return nil }
        // A step-distilled LoRA (Fast mode) makes every one of its few steps count.
        if let fast = model.fastLoRA, request.loras?.contains(where: { $0.source == fast.localURL.path }) == true {
            return nil
        }
        return Self.stepCacheRatio
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
        if !worker.isRunning { try worker.start() }
        let loras = request.loras ?? []
        var message: [String: Any] = [
            "op": "load",
            "family": family,
            "path": model.folder.path,
            "loras": loras.map { ["path": $0.source, "scale": $0.scale] },
            "float16": true,
            "edit": request.references != nil,
        ]
        #if DEBUG
        // -mlxUntiledDecode YES decodes in one pass, to compare against the tiled decode.
        if UserDefaults.standard.bool(forKey: "mlxUntiledDecode") { message["untiled_decode"] = true }
        #endif
        try send(message)
        while true {
            let event = try nextEvent()
            switch event["event"] as? String {
            case "loaded":
                loadedLoRAs = loras
                loadedForEditing = request.references != nil
                return
            case "error":
                throw RuntimeError(event["message"] as? String ?? "MLX worker failed to load the model.")
            default:
                continue
            }
        }
    }

    /// mflux bakes LoRAs into the weights at load, so a different LoRA set needs a reload.
    /// Edit with words loads the family's editing pipeline, and plain pictures the usual one.
    func needsReload(for request: GenerationRequest) -> Bool {
        loadedLoRAs != (request.loras ?? []) || loadedForEditing != (request.references != nil)
    }

    func generate(
        _ request: GenerationRequest,
        previewEvery: Int,
        onStep: (Int, Int, CGImage?) -> Bool
    ) throws -> CGImage? {
        if request.references != nil, !model.supportsEditing {
            throw RuntimeError("\(model.name) can't edit pictures from words. Pick FLUX.2 Klein or FLUX 3 Klein.")
        }
        if request.startImage != nil, !model.supportsStartImage {
            throw RuntimeError("\(model.name) can't start from a picture. Remove the start image, or pick another model.")
        }
        if loadedLoRAs == nil || needsReload(for: request) { try load(for: request) }

        let size = (request.aspect ?? .square).size(base: model.resolution)
        let out = FileManager.default.temporaryDirectory.appending(path: "mlx-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let supportsNegative = model.defaults?.supportsNegativePrompt ?? true
        var optional: [String: Any] = [:]
        if let path = request.startImage {
            // mflux's image_strength is the share of steps skipped (higher keeps more of
            // the image), the inverse of `change`.
            optional["image_path"] = path
            optional["image_strength"] = 1 - min(max(request.change ?? 0.6, 0.05), 1)
        }
        if let references = request.references { optional["reference_paths"] = references }
        // Set by the generator through withSpeedSettings, so the saved record matches the run.
        if let ratio = request.stepCacheRatio { optional["step_cache_ratio"] = ratio }
        try send(optional.merging([
            "op": "generate",
            "prompt": request.prompt,
            "negative_prompt": supportsNegative ? request.negativePrompt : "",
            "seed": Int(request.seed),
            "steps": request.steps,
            "guidance": request.guidance,
            "width": size.width,
            "height": size.height,
            "out": out.path,
            "preview_every": Self.previewInterval(setting: previewEvery, steps: request.steps),
        ]) { a, _ in a })
        runningSteps.value = request.steps
        defer { runningSteps.value = 0 }

        var cancelSent = false
        var lastStep = (0, request.steps)
        func reportStep(_ step: Int, _ total: Int, _ preview: CGImage?) {
            if !onStep(step, total, preview), !cancelSent, let pid = worker.processIdentifier {
                kill(pid, SIGUSR1)  // the worker stops at its next step
                cancelSent = true
            }
        }
        while true {
            let event = try nextEvent()
            switch event["event"] as? String {
            case "step":
                let step = event["step"] as? Int ?? 0
                let total = event["total"] as? Int ?? request.steps
                lastStep = (step, total)
                reportStep(step, total, nil)
            case "preview":
                guard let path = event["path"] as? String else { continue }
                let url = URL(filePath: path)
                let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
                let preview = CGImageSourceCreateWithURL(url as CFURL, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
                try? FileManager.default.removeItem(at: url)
                #if DEBUG
                print("[mlx] preview at step \(event["step"] ?? "?"): \(String(format: "%.2f", event["seconds"] as? Double ?? 0)) s")
                #endif
                if let preview { reportStep(lastStep.0, lastStep.1, preview) }
            case "encoded":
                #if DEBUG
                let cached = event["cached"] as? Bool ?? false
                print("[mlx] prompt encoding: \(cached ? "reused" : String(format: "%.2f s", event["seconds"] as? Double ?? 0))")
                #endif
                continue
            case "done":
                #if DEBUG
                print("[mlx] peak MLX memory: \(String(format: "%.1f", event["peak_gb"] as? Double ?? 0)) GB")
                #endif
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

    /// MLX models run few, slow steps (4–9 at 15–20 s each), so "every 5 steps" would rarely
    /// show anything. Aim for about three previews per image, never sparser than the setting.
    static func previewInterval(setting: Int, steps: Int) -> Int {
        guard setting > 0 else { return 0 }
        return max(1, min(setting, steps / 3))
    }

    /// The worker reads stdin on its own thread, so this reaches it mid-picture.
    func setPreviewEvery(_ every: Int) {
        let steps = runningSteps.value
        guard steps > 0 else { return }
        try? send(["op": "preview", "every": Self.previewInterval(setting: every, steps: steps)])
    }

    func unload() {
        worker.terminate()
        loadedLoRAs = nil
    }

    deinit { unload() }

    // MARK: Worker process

    private func send(_ message: [String: Any]) throws {
        try worker.send(message)
    }

    private func nextEvent() throws -> [String: Any] {
        do {
            return try worker.nextEvent()
        } catch let stopped as MLXWorker.Stopped {
            loadedLoRAs = nil
            // A worker killed for using too much memory exits with SIGKILL (status 9).
            throw RuntimeError("The MLX worker stopped\(stopped.status.map { " (status \($0))" } ?? ""), "
                               + "most likely out of memory. Try a smaller size or model. Log: \(MLXRuntime.logURL.path)")
        }
    }
}
