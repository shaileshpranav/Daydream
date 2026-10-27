import Foundation

enum SchedulerChoice: String, Codable, CaseIterable, Identifiable {
    case dpmSolver = "DPM-Solver++"
    case pndm = "PNDM"

    var id: String { rawValue }
}

/// Output shape for models that take any size (MLX). Core ML models ignore it.
enum AspectChoice: String, Codable, CaseIterable, Identifiable {
    case square = "1:1"
    case portrait = "3:4"
    case landscape = "4:3"
    case wide = "16:9"
    case tall = "9:16"

    var id: String { rawValue }

    /// Width and height for a model whose base resolution is `base` (the long side for
    /// non-square shapes keeps roughly the same pixel count), rounded to multiples of 64.
    func size(base: Int) -> (width: Int, height: Int) {
        let ratio: Double = switch self {
        case .square: 1
        case .portrait: 3.0 / 4.0
        case .landscape: 4.0 / 3.0
        case .wide: 16.0 / 9.0
        case .tall: 9.0 / 16.0
        }
        let area = Double(base * base)
        func round64(_ x: Double) -> Int { max(256, Int((x / 64).rounded()) * 64) }
        return (round64((area * ratio).squareRoot()), round64((area / ratio).squareRoot()))
    }
}

/// A LoRA applied when an MLX model loads: a local .safetensors path or a Hugging Face repo.
struct LoRARef: Codable, Hashable, Identifiable {
    var source: String
    var scale: Double = 1.0
    /// Detected when the LoRA was added; used to drop it when switching to another base model.
    var base: LoRABase?

    var id: String { source }
    var name: String { URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent }
}

/// Everything needed to reproduce an image with a given model.
struct GenerationRequest: Codable, Equatable {
    var prompt: String = ""
    var negativePrompt: String = ""
    var steps: Int = 25
    var guidance: Double = 7.5
    var seed: UInt32 = 42
    var scheduler: SchedulerChoice = .dpmSolver
    // Optional so records saved before these existed still decode.
    var aspect: AspectChoice? = .square
    var loras: [LoRARef]? = []
    /// Image-to-image: a start image (a copy in StartImages.folder) and how much to
    /// change it, 0 = keep it as is, 1 = ignore it entirely.
    var startImage: String?
    var change: Double? = 0.6

    var isImageToImage: Bool { startImage != nil }

    mutating func randomizeSeed() {
        seed = UInt32.random(in: 0...UInt32.max)
    }
}

/// Written next to every saved PNG so the gallery can restore settings.
struct GenerationRecord: Codable, Identifiable, Hashable {
    var id: String { fileName }
    let fileName: String
    let request: GenerationRequest
    let modelID: String
    let modelName: String
    let date: Date
    let seconds: Double

    static func == (a: GenerationRecord, b: GenerationRecord) -> Bool { a.fileName == b.fileName }
    func hash(into hasher: inout Hasher) { hasher.combine(fileName) }
}
