import CoreML
import Foundation
import StableDiffusion

/// SD 1.x / 2.x / XL via Apple's ml-stable-diffusion package.
final class StableDiffusionBackend: ImageBackend {
    let model: InstalledModel
    private var pipeline: StableDiffusionPipelineProtocol?

    init(model: InstalledModel) {
        self.model = model
    }

    private var isXL: Bool { model.kind == .sdxl }

    /// UserDefaults key for "Faster GPU maths" in Settings.
    static let lowPrecisionKey = "lowPrecisionGPU"

    /// Whether the GPU may accumulate in 16-bit instead of 32-bit. Only matters when the
    /// model runs on the GPU (CPU + GPU, or All); the Neural Engine is 16-bit anyway.
    private var wantsLowPrecision: Bool {
        model.computeUnits != .cpuAndNeuralEngine && UserDefaults.standard.bool(forKey: Self.lowPrecisionKey)
    }
    private var loadedLowPrecision: Bool?

    /// Changing the setting needs a reload: it's part of the model configuration.
    func needsReload(for request: GenerationRequest) -> Bool {
        pipeline != nil && loadedLowPrecision != wantsLowPrecision
    }

    /// Records the GPU accumulation the loaded pipeline uses. On the Neural Engine
    /// (16-bit anyway) the setting doesn't apply, so nothing is recorded.
    func withSpeedSettings(_ request: GenerationRequest) -> GenerationRequest {
        var recorded = request
        recorded.fasterGPUMaths = model.computeUnits == .cpuAndNeuralEngine ? nil : (loadedLowPrecision ?? wantsLowPrecision)
        return recorded
    }

    func load() throws {
        pipeline?.unloadResources()
        pipeline = nil
        let config = MLModelConfiguration()
        config.computeUnits = model.computeUnits.mlValue
        let lowPrecision = wantsLowPrecision
        config.allowLowPrecisionAccumulationOnGPU = lowPrecision
        loadedLowPrecision = lowPrecision
        let pipeline: StableDiffusionPipelineProtocol
        if isXL {
            // On 16 GB, SDXL only fits if the text encoders and VAE are loaded on demand.
            pipeline = try StableDiffusionXLPipeline(resourcesAt: model.folder, configuration: config, reduceMemory: true)
        } else {
            pipeline = try StableDiffusionPipeline(resourcesAt: model.folder, controlNet: [], configuration: config,
                                                   disableSafety: true, reduceMemory: false)
        }
        try pipeline.loadResources()
        self.pipeline = pipeline
    }

    func generate(
        _ request: GenerationRequest,
        previewEvery: Int,
        onStep: (Int, Int, CGImage?) -> Bool
    ) throws -> CGImage? {
        if pipeline == nil { try load() }
        guard let pipeline else { throw BackendError.noImage }

        var config = PipelineConfiguration(prompt: request.prompt)
        config.negativePrompt = request.negativePrompt
        config.stepCount = request.steps
        config.seed = request.seed
        config.guidanceScale = Float(request.guidance)
        config.disableSafety = true
        config.schedulerType = request.scheduler == .dpmSolver ? .dpmSolverMultistepScheduler : .pndmScheduler
        if isXL {
            config.encoderScaleFactor = 0.13025
            config.decoderScaleFactor = 0.13025
        }
        if let path = request.startImage {
            // Core ML models take a start image of exactly their fixed size. `strength`
            // is how much to change it (1 ignores it), the same sense as `change`.
            guard let image = StartImages.load(path),
                  let sized = StartImages.fill(image, width: model.resolution, height: model.resolution)
            else { throw RuntimeError("Couldn't read the start image.") }
            config.startingImage = sized
            config.strength = Float(min(max(request.change ?? 0.6, 0.05), 1))
        }

        var cancelled = false
        let images = try pipeline.generateImages(configuration: config) { progress in
            let step = progress.step + 1
            let wantsPreview = previewEvery > 0 && step % previewEvery == 0 && step < progress.stepCount
            let preview = wantsPreview ? progress.currentImages.first ?? nil : nil
            if !onStep(step, progress.stepCount, preview) { cancelled = true }
            return !cancelled
        }
        if cancelled { throw CancellationError() }
        guard let image = images.first ?? nil else { throw BackendError.noImage }
        return image
    }

    func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }
}
