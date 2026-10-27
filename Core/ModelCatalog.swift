import CoreML
import Foundation

enum ModelKind: String, Codable, CaseIterable {
    case sd          // SD 1.x / 2.x
    case sdxl
    case zimage      // Z-Image-Turbo (not yet runnable, see README)
    case qwenImage   // Qwen-Image (not yet runnable, see README)

    var label: String {
        switch self {
        case .sd: "Stable Diffusion 1.x/2.x"
        case .sdxl: "Stable Diffusion XL"
        case .zimage: "Z-Image"
        case .qwenImage: "Qwen-Image"
        }
    }

    /// Whether this app has a backend for the kind yet.
    var isRunnable: Bool { self == .sd || self == .sdxl }
}

enum ComputeUnitsChoice: String, Codable, CaseIterable, Identifiable {
    case cpuAndNeuralEngine
    case cpuAndGPU
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpuAndNeuralEngine: "CPU + Neural Engine"
        case .cpuAndGPU: "CPU + GPU"
        case .all: "All"
        }
    }

    var mlValue: MLComputeUnits {
        switch self {
        case .cpuAndNeuralEngine: .cpuAndNeuralEngine
        case .cpuAndGPU: .cpuAndGPU
        case .all: .all
        }
    }
}

/// A downloadable model, described in catalog.json.
/// Either `zip` (one archive in the repo) or `folder` (a path prefix whose files are fetched one by one) is set.
struct CatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ModelKind
    let repo: String
    let zip: String?
    let folder: String?
    let exclude: [String]?
    let computeUnits: ComputeUnitsChoice
    let resolution: Int
    let approxGB: Double
    let notes: String?
    let license: String?
}

enum ModelCatalog {
    static let entries: [CatalogEntry] = {
        guard let url = Bundle.main.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([CatalogEntry].self, from: data)
        else {
            assertionFailure("catalog.json missing or invalid")
            return []
        }
        return entries
    }()
}

/// A model on disk. Stored as `model.json` in the model's folder.
struct InstalledModel: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let kind: ModelKind
    var computeUnits: ComputeUnitsChoice
    let resolution: Int
    /// LoRAs fused into the weights at conversion time (tools/convert --lora).
    var loras: [FusedLoRA]?
    /// Not persisted; set when the folder is scanned.
    var folder: URL!

    enum CodingKeys: String, CodingKey { case id, name, kind, computeUnits, resolution, loras }
}

struct FusedLoRA: Codable, Hashable {
    let name: String
    let source: String
    let scale: Double

    var label: String { "\(name) × \(scale.formatted())" }
}
