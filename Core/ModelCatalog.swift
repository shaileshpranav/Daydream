import CoreML
import Foundation

enum ModelKind: String, Codable, CaseIterable {
    case sd          // SD 1.x / 2.x, Core ML
    case sdxl        // Core ML
    case mlx         // any mflux family (Z-Image, FLUX.2, Qwen-Image…), see MLXBackend

    var label: String {
        switch self {
        case .sd: "Stable Diffusion 1.x/2.x"
        case .sdxl: "Stable Diffusion XL"
        case .mlx: "MLX"
        }
    }

    /// Whether this app has a backend for the kind yet.
    var isRunnable: Bool { true }

    /// Core ML models are converted with a fixed output size; MLX models take any size.
    var hasFixedSize: Bool { self != .mlx }
}

/// Per-model defaults applied when the model is picked (e.g. Z-Image Turbo: 9 steps, no guidance).
struct ModelDefaults: Codable, Hashable {
    let steps: Int
    let guidance: Double
    var supportsNegativePrompt: Bool? = true
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
    /// For `kind == .mlx`: which mflux model family the weights are (see mlx_worker.py).
    let mlxFamily: String?
    let defaults: ModelDefaults?
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
    var name: String
    let kind: ModelKind
    var computeUnits: ComputeUnitsChoice
    var resolution: Int
    /// LoRAs fused into the weights at conversion time (tools/convert --lora).
    var loras: [FusedLoRA]?
    var mlxFamily: String?
    var defaults: ModelDefaults?
    /// Hugging Face repo it was downloaded from, if any.
    var source: String?
    /// Not persisted; set when the folder is scanned.
    var folder: URL!

    enum CodingKeys: String, CodingKey { case id, name, kind, computeUnits, resolution, loras, mlxFamily, defaults, source }

    /// The catalog entry this model was installed from, for notes, license and built-in defaults.
    var catalogEntry: CatalogEntry? { ModelCatalog.entries.first { $0.id == id } }

    /// The defaults it shipped with, before any edits in the model manager.
    var builtInDefaults: ModelDefaults? { catalogEntry?.defaults ?? MLXFamilies.family(id: mlxFamily)?.defaults }

    var backendLabel: String {
        switch kind {
        case .mlx: "MLX · \(MLXFamilies.family(id: mlxFamily)?.label ?? mlxFamily ?? "unknown family")"
        case .sd, .sdxl: "Core ML · \(kind.label)"
        }
    }

    /// The LoRA base this model accepts at generation time (MLX models only).
    var loraBase: LoRABase? { LoRABase.forMLXFamily(mlxFamily) }

    /// The few-step LoRA behind Fast mode, if this model's family has one.
    var fastLoRA: FastLoRA? { kind == .mlx ? MLXFamilies.family(id: mlxFamily)?.fastLoRA : nil }

    /// Core ML models and most MLX families can start from a picture; MOSS-Image can't.
    var supportsStartImage: Bool {
        kind != .mlx || (MLXFamilies.family(id: mlxFamily)?.supportsStartImage ?? true)
    }

    /// Steps and guidance this model is tuned for; SD defaults for Core ML models.
    var recommended: ModelDefaults {
        defaults ?? ModelDefaults(steps: kind == .sdxl ? 30 : 25, guidance: 7.5)
    }
}

struct FusedLoRA: Codable, Hashable {
    let name: String
    let source: String
    let scale: Double

    var label: String { "\(name) × \(scale.formatted())" }
}
