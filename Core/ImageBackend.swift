import CoreGraphics
import Foundation

/// One model family's inference pipeline. Calls are synchronous and made from
/// the generator's inference queue, never the main thread.
protocol ImageBackend: AnyObject {
    var model: InstalledModel { get }

    func load() throws

    /// Loads for a specific request, for backends whose loaded state depends on it
    /// (MLX bakes the request's LoRAs into the weights).
    func load(for request: GenerationRequest) throws

    /// True when the loaded state can't serve `request` and `load(for:)` must run again.
    func needsReload(for request: GenerationRequest) -> Bool

    /// `request` with the speed settings this backend applies to it under the current
    /// Settings (step reuse, faster GPU maths) filled in, so the saved picture records them.
    func withSpeedSettings(_ request: GenerationRequest) -> GenerationRequest

    /// `onStep(step, total, preview)` returns false to cancel. `preview` is non-nil
    /// only on steps where `previewEvery` asks for one.
    func generate(
        _ request: GenerationRequest,
        previewEvery: Int,
        onStep: (Int, Int, CGImage?) -> Bool
    ) throws -> CGImage?

    func unload()
}

extension ImageBackend {
    func load(for request: GenerationRequest) throws { try load() }
    func needsReload(for request: GenerationRequest) -> Bool { false }
    func withSpeedSettings(_ request: GenerationRequest) -> GenerationRequest { request }
}

enum BackendError: LocalizedError {
    case unsupported(ModelKind)
    case noImage

    var errorDescription: String? {
        switch self {
        case .unsupported(let kind): "\(kind.label) models don't have a backend yet."
        case .noImage: "The pipeline returned no image."
        }
    }
}

enum Backends {
    static func make(for model: InstalledModel) throws -> ImageBackend {
        switch model.kind {
        case .sd, .sdxl: StableDiffusionBackend(model: model)
        case .mlx: MLXBackend(model: model)
        }
    }
}
