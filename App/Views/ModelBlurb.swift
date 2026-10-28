import Foundation

/// Plain-language descriptions of models, for people who don't know what "SDXL" or "MLX" means.
enum ModelBlurb {
    /// The model offered on the welcome screen: small, fast, and needs no extra setup.
    static let starterID = "sd15-palettized"

    static func tagline(for model: InstalledModel) -> String {
        tagline(id: model.id, kind: model.kind, family: model.mlxFamily, notes: model.catalogEntry?.notes)
    }

    static func tagline(id: String, kind: ModelKind, family: String? = nil, notes: String?) -> String {
        if let known = taglines[id] { return known }
        switch MLXFamilies.family(id: family)?.id ?? family {
        case "z-image-turbo", "z-image": return "Realistic photos with lots of detail"
        case "flux2-klein-4b", "flux2-klein-9b": return "Quick, sharp pictures in any style"
        case "qwen-image-2.1-turbo", "qwen-image-2.1": return "Follows long descriptions and draws text well"
        case "moss-image", "moss-image-base": return "Posters and signs with clear, correctly spelled text"
        case "flux3-klein": return "Sharp, modern pictures in any style"
        case "iris-3b-turbo": return "Small and quick, in a few steps"
        case "anima-turbo", "anima-aesthetic", "anima-base": return "Anime and illustration"
        case "ernie-image-turbo", "ernie-image": return "Realistic photos, and it can change your own pictures"
        default: break
        }
        switch kind {
        case .sd: return "A small, quick all-rounder"
        case .sdxl: return "Detailed, large pictures"
        case .mlx: return notes ?? "A newer model in any shape"
        }
    }

    /// How quick a model is compared with the others, for choosing one.
    /// (SDXL measured at 7.7 s per step × 30 steps on an M1 Pro.)
    static func speed(id: String) -> String? {
        switch id {
        case "sd15-palettized", "sd21-base-palettized", "mlx-flux2-klein-4b-q4": "fast"
        case "sd15", "mlx-z-image-turbo-q4": "medium speed"
        case "mlx-qwen-image-2.1-turbo-q4": "slow"
        case "mlx-moss-image-sft-q4": "very slow at 50 steps; quick with the 8-step LoRA"
        // Not measured on this Mac yet: going by step counts and the mflux READMEs.
        case "mlx-iris-3b-turbo-q4", "mlx-anima-turbo-q4": "fast"
        case "mlx-ernie-image-turbo-q4": "medium speed"
        case "mlx-flux3-klein-q4": "slow"
        case "sdxl-base-mbp-4.5": "slow: about 4 minutes a picture"
        default: nil
        }
    }

    private static let taglines: [String: String] = [
        "sd15-palettized": "Small and quick. A good first model",
        "sd15": "The classic all-rounder, slightly sharper than the small one",
        "sd21-base-palettized": "Smallest download, simple pictures",
        "sdxl-base-mbp-4.5": "Big, detailed square pictures, but slow",
        "mlx-z-image-turbo-q4": "Realistic photos with lots of detail",
        "mlx-flux2-klein-4b-q4": "Quick, sharp pictures in any shape and style",
        "mlx-qwen-image-2.1-turbo-q4": "Follows long descriptions and draws text well. Needs lots of memory",
        "mlx-moss-image-sft-q4": "Posters and signs with clear text, in English or Chinese",
        "mlx-iris-3b-turbo-q4": "Small and quick, in just 4 steps",
        "mlx-anima-turbo-q4": "Anime and illustration. Smallest MLX model",
        "mlx-flux3-klein-q4": "Sharp, modern pictures in any style",
        "mlx-ernie-image-turbo-q4": "Realistic photos in 8 steps, and it can change your own pictures",
    ]
}
