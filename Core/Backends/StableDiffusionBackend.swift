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

    func load() throws {
        let config = MLModelConfiguration()
        config.computeUnits = model.computeUnits.mlValue
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
