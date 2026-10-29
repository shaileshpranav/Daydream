import Foundation

/// An mflux model family the worker can load (see make_model() in mlx_worker.py),
/// with the settings it's tuned for.
struct MLXFamily: Identifiable, Hashable {
    let id: String
    let label: String
    let defaults: ModelDefaults
    /// Base resolution; MLX models take any aspect around this many pixels squared.
    let resolution: Int
    /// Whether mflux can start this family from a picture (image-to-image).
    var supportsStartImage = true
    /// Whether the family's mflux pipeline can reuse the model output on near-identical
    /// steps (mflux's step_cache_ratio; only takes effect at 10 steps or more).
    var supportsStepCache = false
    /// A step-distillation LoRA that makes the family usable in far fewer steps (Fast mode).
    var fastLoRA: FastLoRA?
    /// Whether the worker runs it with float16 compute (mflux's compute_precision).
    var float16Compute = true
    /// Measured peak memory above MemoryEstimate's generic formula, where it was known to be low.
    var extraMemoryGB = 0.0
}

/// A community LoRA distilled for few steps without CFG. Fast mode downloads it once into
/// the Loras folder (LoRALibrary.download) and adds it with these settings.
struct FastLoRA: Hashable {
    let repo: String
    let file: String
    let steps: Int
    let guidance: Double
    /// Download size, to say up front what turning Fast mode on costs.
    let approxGB: Double

    /// Where LoRALibrary.download(repo:) puts it.
    var localURL: URL {
        ModelStore.lorasFolder
            .appending(path: repo.replacingOccurrences(of: "/", with: "__"), directoryHint: .isDirectory)
            .appending(path: file)
    }

    var isDownloaded: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    var defaults: ModelDefaults { ModelDefaults(steps: steps, guidance: guidance) }
}

enum MLXFamilies {
    static let all: [MLXFamily] = [
        MLXFamily(id: "z-image-turbo", label: "Z-Image Turbo",
                  defaults: ModelDefaults(steps: 9, guidance: 0), resolution: 1024),
        MLXFamily(id: "z-image", label: "Z-Image (base)",
                  defaults: ModelDefaults(steps: 50, guidance: 4), resolution: 1024),
        MLXFamily(id: "flux2-klein-4b", label: "FLUX.2 Klein 4B",
                  defaults: ModelDefaults(steps: 4, guidance: 1, supportsNegativePrompt: false), resolution: 1024),
        MLXFamily(id: "flux2-klein-9b", label: "FLUX.2 Klein 9B",
                  defaults: ModelDefaults(steps: 4, guidance: 1, supportsNegativePrompt: false), resolution: 1024),
        MLXFamily(id: "qwen-image-2.1-turbo", label: "Qwen-Image 2.1 Turbo",
                  defaults: ModelDefaults(steps: 8, guidance: 1), resolution: 768, supportsStepCache: true),
        MLXFamily(id: "qwen-image-2.1", label: "Qwen-Image 2.1 (base)",
                  defaults: ModelDefaults(steps: 40, guidance: 1), resolution: 768, supportsStepCache: true),
        // MOSS-Image runs CFG as two transformer passes per step, so its 50 steps are slow on
        // an M1 Pro: 768 px keeps the pixel count (and memory) down. mflux has no
        // image-to-image for it. The 8-step DMD LoRA (trained on SFT, not base) runs without
        // CFG: 8 transformer passes instead of 100.
        MLXFamily(id: "moss-image", label: "MOSS-Image (SFT)",
                  defaults: ModelDefaults(steps: 50, guidance: 3), resolution: 768,
                  supportsStartImage: false, supportsStepCache: true,
                  fastLoRA: FastLoRA(repo: "lodestones/MOSS-Image-SFT-8-steps-dmd", file: "lora.safetensors",
                                     steps: 8, guidance: 1, approxGB: 1.2),
                  float16Compute: false, extraMemoryGB: 2.6),
        // Peak memory measured on an M1 Pro at 768 px, 4-bit: 11.7 GB at 50 steps (the formula
        // says 9.2) and 12.9 GB in Fast mode with its LoRA as separate layers.
        MLXFamily(id: "moss-image-base", label: "MOSS-Image (base)",
                  defaults: ModelDefaults(steps: 50, guidance: 3), resolution: 768,
                  supportsStartImage: false, supportsStepCache: true, float16Compute: false, extraMemoryGB: 2.6),
        // Settings from each family's mflux README. Distilled variants ignore guidance and the
        // negative prompt, so those fields hide. FLUX 3 Klein's 1024 px peak memory wasn't
        // published with the current VAE decode, so it starts at 768 px to stay off swap.
        MLXFamily(id: "flux3-klein", label: "FLUX 3 Klein",
                  defaults: ModelDefaults(steps: 16, guidance: 1, supportsNegativePrompt: false), resolution: 768,
                  supportsStartImage: false),
        // Iris denoises pixels directly (no VAE) and has no LoRA or float16 option in mflux.
        MLXFamily(id: "iris-3b-turbo", label: "Iris-3B Turbo",
                  defaults: ModelDefaults(steps: 4, guidance: 1, supportsNegativePrompt: false), resolution: 1024,
                  supportsStartImage: false, float16Compute: false),
        // Anima Turbo peaked at 11.0 GB here at 1024 px, 4-bit, with the decode tiled (18.7 GB in
        // one pass); the formula says 5.1. Aesthetic and base share its architecture.
        MLXFamily(id: "anima-turbo", label: "Anima Turbo",
                  defaults: ModelDefaults(steps: 10, guidance: 1, supportsNegativePrompt: false), resolution: 1024,
                  supportsStartImage: false, extraMemoryGB: 5.9),
        MLXFamily(id: "anima-aesthetic", label: "Anima Aesthetic",
                  defaults: ModelDefaults(steps: 30, guidance: 4), resolution: 1024, supportsStartImage: false,
                  extraMemoryGB: 5.9),
        MLXFamily(id: "anima-base", label: "Anima (base)",
                  defaults: ModelDefaults(steps: 30, guidance: 4), resolution: 1024, supportsStartImage: false,
                  extraMemoryGB: 5.9),
        // mflux rejects any guidance but 1 on ERNIE-Image Turbo.
        MLXFamily(id: "ernie-image-turbo", label: "ERNIE-Image Turbo",
                  defaults: ModelDefaults(steps: 8, guidance: 1, supportsNegativePrompt: false), resolution: 1024,
                  float16Compute: false),
        MLXFamily(id: "ernie-image", label: "ERNIE-Image (base)",
                  defaults: ModelDefaults(steps: 50, guidance: 4), resolution: 1024, float16Compute: false),
    ]

    static func family(id: String?) -> MLXFamily? {
        all.first { $0.id == id }
    }

    /// Guesses the family from a repo name such as "mflux-community/z-image-turbo-mflux-q4".
    /// Variants the worker can't run (edit, ControlNet, KV, Klein base) return nil.
    static func detect(repo: String) -> MLXFamily? {
        let name = repo.lowercased()
            .split(separator: "/").last.map(String.init)?
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-") ?? ""
        if ["edit", "controlnet", "kontext", "fill", "depth"].contains(where: name.contains) { return nil }
        if name.contains("z-image") || name.contains("zimage") {
            return family(id: name.contains("turbo") ? "z-image-turbo" : "z-image")
        }
        // Before "klein": FLUX 3 Klein repos also contain it. The undistilled base isn't offered.
        if name.contains("flux-3") || name.contains("flux3") {
            return name.contains("klein") && !name.contains("base") ? family(id: "flux3-klein") : nil
        }
        if name.contains("iris-3b") || name.contains("iris3b") {
            return name.contains("turbo") ? family(id: "iris-3b-turbo") : nil  // base: 100 steps
        }
        if name.contains("anima"), !name.contains("animagine") {
            if name.contains("aesthetic") { return family(id: "anima-aesthetic") }
            return family(id: name.contains("base") ? "anima-base" : "anima-turbo")
        }
        if name.contains("ernie-image") || name.contains("ernieimage") {
            return family(id: name.contains("turbo") ? "ernie-image-turbo" : "ernie-image")
        }
        if name.contains("klein") {
            if name.contains("base") || name.contains("-kv") { return nil }
            if name.contains("9b") { return family(id: "flux2-klein-9b") }
            if name.contains("4b") { return family(id: "flux2-klein-4b") }
            return nil
        }
        if name.contains("qwen-image-2-1") || name.contains("qwen-image-21") || name.contains("qwenimage21") {
            return family(id: name.contains("turbo") ? "qwen-image-2.1-turbo" : "qwen-image-2.1")
        }
        if name.contains("moss-image") || name.contains("mossimage") {
            return family(id: name.contains("base") ? "moss-image-base" : "moss-image")
        }
        return nil
    }

    /// "q4", "q8", "bf16"… from an mflux repo name, for display.
    static func quantization(repo: String) -> String? {
        let name = repo.lowercased()
        for q in ["q3", "q4", "q5", "q6", "q8", "4bit", "8bit", "bf16", "fp8"] where name.contains(q) {
            return q.replacingOccurrences(of: "bit", with: "-bit")
        }
        return nil
    }
}

/// Rough peak memory while generating, to warn before a model is too big for this Mac.
enum MemoryEstimate {
    static let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    enum Fit {
        case comfortable, tight, tooBig

        var label: String {
            switch self {
            case .comfortable: "Fits comfortably"
            case .tight: "Tight: close other apps"
            case .tooBig: "Likely to swap or fail"
            }
        }
    }

    static func gigabytes(weightsGB: Double, kind: ModelKind, resolution: Int, family: String? = nil) -> Double {
        switch kind {
        case .mlx:
            // Weights, activations that grow with the pixel count, and the Python worker.
            let megapixels = Double(resolution * resolution) / (1024 * 1024)
            let extra = MLXFamilies.family(id: family)?.extraMemoryGB ?? 0
            return weightsGB * 1.05 + 1.2 * megapixels + 0.6 + extra
        case .sdxl:
            // Reduced-memory mode keeps only the UNet resident during denoising.
            return weightsGB * 0.85 + 1.0
        case .sd:
            return weightsGB * 1.15 + 0.5
        }
    }

    /// macOS and other apps need ~4 GB, so "comfortable" leaves that free.
    static func fit(_ gigabytes: Double) -> Fit {
        if gigabytes < ramGB * 0.6 { return .comfortable }
        if gigabytes < ramGB * 0.85 { return .tight }
        return .tooBig
    }
}
