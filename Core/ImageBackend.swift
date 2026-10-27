import CoreGraphics
import Foundation

/// One model family's inference pipeline. Calls are synchronous and made from
/// the generator's inference queue, never the main thread.
protocol ImageBackend: AnyObject {
    var model: InstalledModel { get }

    func load() throws

    /// `onStep(step, total, preview)` returns false to cancel. `preview` is non-nil
    /// only on steps where `previewEvery` asks for one.
    func generate(
        _ request: GenerationRequest,
        previewEvery: Int,
        onStep: (Int, Int, CGImage?) -> Bool
    ) throws -> CGImage?

    func unload()
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
        case .zimage, .qwenImage: throw BackendError.unsupported(model.kind)
        }
    }
}
