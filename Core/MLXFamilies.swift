import Foundation

/// An mflux model family the worker can load (see make_model() in mlx_worker.py),
/// with the settings it's tuned for.
struct MLXFamily: Identifiable, Hashable {
    let id: String
    let label: String
    let defaults: ModelDefaults
    /// Base resolution; MLX models take any aspect around this many pixels squared.
    let resolution: Int
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
                  defaults: ModelDefaults(steps: 8, guidance: 1), resolution: 768),
        MLXFamily(id: "qwen-image-2.1", label: "Qwen-Image 2.1 (base)",
                  defaults: ModelDefaults(steps: 40, guidance: 1), resolution: 768),
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
        if name.contains("klein") {
            if name.contains("base") || name.contains("-kv") { return nil }
            if name.contains("9b") { return family(id: "flux2-klein-9b") }
            if name.contains("4b") { return family(id: "flux2-klein-4b") }
            return nil
        }
        if name.contains("qwen-image-2-1") || name.contains("qwen-image-21") || name.contains("qwenimage21") {
            return family(id: name.contains("turbo") ? "qwen-image-2.1-turbo" : "qwen-image-2.1")
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

    static func gigabytes(weightsGB: Double, kind: ModelKind, resolution: Int) -> Double {
        switch kind {
        case .mlx:
            // Weights, activations that grow with the pixel count, and the Python worker.
            let megapixels = Double(resolution * resolution) / (1024 * 1024)
            return weightsGB * 1.05 + 1.2 * megapixels + 0.6
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
