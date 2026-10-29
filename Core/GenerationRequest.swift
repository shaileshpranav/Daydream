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
    var name: String {
        // A Hugging Face "repo:file" reference is named after its repo.
        let path = source.hasPrefix("/") ? source : String(source.prefix { $0 != ":" })
        let url = URL(fileURLWithPath: path)
        let name = url.deletingPathExtension().lastPathComponent
        // A file downloaded as Loras/<owner>__<repo>/lora.safetensors: name it after the repo.
        if name.lowercased() == "lora", url.deletingLastPathComponent().lastPathComponent.contains("__") {
            return String(url.deletingLastPathComponent().lastPathComponent.split(separator: "__").last ?? "")
        }
        return name
    }
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
    /// Edit with words: the pictures an editing model works from (copies in
    /// StartImages.folder), the picture being edited first. Nil for an ordinary picture.
    var references: [String]?
    /// Share of steps whose model output was reused ("Skip near-identical steps" in
    /// Settings). Filled in by the generator from the setting at the time, so a saved
    /// picture records it; nil when nothing was skipped.
    var stepCacheRatio: Double?
    /// Whether a Core ML model on the GPU accumulated in 16-bit ("Faster GPU maths" in
    /// Settings). Filled in like stepCacheRatio; nil on the Neural Engine and for MLX.
    var fasterGPUMaths: Bool?

    var isImageToImage: Bool { startImage != nil }

    mutating func randomizeSeed() {
        seed = UInt32.random(in: 0...UInt32.max)
    }
}

/// How an upscaled picture was made from its original.
struct UpscaleInfo: Codable, Hashable {
    let scale: Int
    /// The original picture's file name.
    let source: String
    let model: String
    let seconds: Double
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
    /// Set on an upscaled copy; `request` and the model are the original picture's.
    var upscale: UpscaleInfo? = nil
    /// Set on a picture saved from the Edit section: the steps applied, in order, and the
    /// picture they started from (nil for a file opened from disk).
    var edits: [String]? = nil
    var editedFrom: String? = nil

    static func == (a: GenerationRecord, b: GenerationRecord) -> Bool { a.fileName == b.fileName }
    func hash(into hasher: inout Hasher) { hasher.combine(fileName) }
}
