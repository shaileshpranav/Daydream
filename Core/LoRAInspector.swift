import Foundation

/// The base model a LoRA was trained for. A LoRA only works on its own base: the
/// layer names and sizes must match the model's weights.
enum LoRABase: String, Codable, CaseIterable {
    case sd15, sdxl, flux1, flux2Klein4B, flux2Klein9B, zImage, qwenImage, qwenImage21, mossImage
    case flux3Klein, anima, ernieImage

    var label: String {
        switch self {
        case .sd15: "SD 1.5"
        case .sdxl: "SDXL"
        case .flux1: "FLUX.1"
        case .flux2Klein4B: "FLUX.2 Klein 4B"
        case .flux2Klein9B: "FLUX.2 Klein 9B"
        case .zImage: "Z-Image"
        case .qwenImage: "Qwen-Image"
        case .qwenImage21: "Qwen-Image 2.1"
        case .mossImage: "MOSS-Image"
        case .flux3Klein: "FLUX 3 Klein"
        case .anima: "Anima"
        case .ernieImage: "ERNIE-Image"
        }
    }

    /// The LoRA base an MLX model family accepts (Turbo and Base variants share LoRAs).
    static func forMLXFamily(_ family: String?) -> LoRABase? {
        switch family {
        case "z-image-turbo", "z-image": .zImage
        case "flux2-klein-4b": .flux2Klein4B
        case "flux2-klein-9b": .flux2Klein9B
        case "qwen-image-2.1-turbo", "qwen-image-2.1": .qwenImage21
        case "moss-image", "moss-image-base": .mossImage
        case "flux3-klein": .flux3Klein
        case "anima-turbo", "anima-aesthetic", "anima-base": .anima
        case "ernie-image-turbo", "ernie-image": .ernieImage
        default: nil  // Iris-3B takes no LoRAs in mflux
        }
    }

    /// Parses the base-model strings training tools write, e.g. kohya/ai-toolkit's
    /// `ss_base_model_version` ("flux2_klein_4b", "sdxl_base_v1-0") or
    /// `modelspec.architecture` ("stable-diffusion-xl-v1-base/lora").
    init?(metadata value: String) {
        let s = value.lowercased().filter { $0.isLetter || $0.isNumber }
        if s.contains("flux3") { self = .flux3Klein; return }
        if s.contains("erniei") { self = .ernieImage; return }
        // "animagine" is an SDXL fine-tune, not Anima.
        if s.hasPrefix("anima"), !s.hasPrefix("animagine") { self = .anima; return }
        if s.contains("flux2") || s.contains("fluxdot2") {
            if s.contains("9b") { self = .flux2Klein9B; return }
            if s.contains("4b") || s.contains("klein") { self = .flux2Klein4B; return }
            return nil
        }
        if s.contains("zimage") { self = .zImage; return }
        if s.contains("mossimage") { self = .mossImage; return }
        if s.contains("qwen") {
            self = s.contains("21") ? .qwenImage21 : .qwenImage
            return
        }
        if s.contains("flux") { self = .flux1; return }
        if s.contains("sdxl") || s.contains("stablediffusionxl") { self = .sdxl; return }
        if s.contains("sdv1") || s.contains("sd15") || s.contains("stablediffusionv1") { self = .sd15; return }
        return nil
    }
}

enum LoRAInspector {
    enum Result: Equatable {
        case known(LoRABase)
        case unknown(String)
    }

    private static let cache = NSCache<NSString, Box>()
    private final class Box { let result: Result; init(_ r: Result) { result = r } }

    /// Detects the base model of a local .safetensors file from its header only.
    static func inspect(file url: URL) -> Result {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(mtime?.timeIntervalSince1970 ?? 0)" as NSString
        if let hit = cache.object(forKey: key) { return hit.result }
        let result = readHeader(url).map(classify(header:)) ?? .unknown("Couldn't read the file's header")
        cache.setObject(Box(result), forKey: key)
        return result
    }

    /// The raw JSON header of a .safetensors file (tensor names, shapes and metadata).
    static func readHeader(_ url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else { return nil }
        let length = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
        guard length > 0, length < 100_000_000 else { return nil }
        return try? handle.read(upToCount: length)
    }

    /// The training metadata a LoRA carries (kohya / ai-toolkit `__metadata__`).
    static func metadata(file url: URL) -> [String: String] {
        guard let header = readHeader(url),
              let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else { return [:] }
        return json["__metadata__"] as? [String: String] ?? [:]
    }

    /// Trigger words suggested by the metadata: an explicit trigger phrase if the trainer
    /// recorded one, else the most frequent caption tags.
    static func suggestedTriggers(_ metadata: [String: String]) -> [String] {
        for key in ["modelspec.trigger_phrase", "trigger_phrase", "trigger_word", "instance_prompt", "ss_trigger_word"] {
            if let value = metadata[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty { return [value] }
        }
        guard let data = metadata["ss_tag_frequency"]?.data(using: .utf8),
              let folders = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else { return [] }
        var counts: [String: Int] = [:]
        for tags in folders.values {
            for (tag, n) in tags {
                let tag = tag.trimmingCharacters(in: .whitespaces)
                if !tag.isEmpty { counts[tag, default: 0] += n }
            }
        }
        return counts.sorted { $0.value > $1.value }.prefix(6).map(\.key)
    }

    /// Detects the base model of a LoRA in a Hugging Face repo by fetching only its
    /// .safetensors header with HTTP range requests (a few KB, not the whole file).
    /// `reference` is what mflux should load: the bare repo when it holds one .safetensors
    /// file, else "repo:file" (mflux refuses a bare repo with several files).
    static func inspect(repo: String) async throws -> (file: String, reference: String, result: Result) {
        let files = try await HuggingFace.listFiles(repo: repo, prefix: "")
            .filter { $0.path.hasSuffix(".safetensors") }
        guard let file = loraFile(in: files) else {
            throw RuntimeError("\(repo) has no .safetensors file.")
        }
        let url = HuggingFace.resolveURL(repo: repo, path: file.path)
        let lengthData = try await fetch(url, range: 0...7)
        guard lengthData.count == 8 else { throw RuntimeError("Couldn't read \(file.path)'s header.") }
        let length = Int(lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian })
        guard length > 0, length < 100_000_000 else { throw RuntimeError("\(file.path) isn't a valid .safetensors file.") }
        let header = try await fetch(url, range: 8...(8 + length - 1))
        let reference = files.count == 1 ? repo : "\(repo):\(file.path)"
        return (file.path, reference, classify(header: header))
    }

    /// The LoRA among a repo's .safetensors files. Repos such as distillation LoRAs also ship
    /// small helper weights (time embeddings) and a full transformer in a subfolder, so prefer
    /// a top-level file named like a LoRA ("lora.safetensors" over "lora_latest.safetensors"),
    /// then the smallest top-level file.
    static func loraFile(in files: [HFFile]) -> HFFile? {
        let topLevel = files.filter { !$0.path.contains("/") }
        let candidates = topLevel.isEmpty ? files : topLevel
        let named = candidates.filter { $0.path.lowercased().contains("lora") }
        if let file = named.min(by: { ($0.path.count, $0.size) < ($1.path.count, $1.size) }) { return file }
        return candidates.min { $0.size < $1.size }
    }

    private static func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            throw RuntimeError("Hugging Face returned HTTP \(http.statusCode) for \(url.lastPathComponent).")
        }
        return data.prefix(range.count)
    }

    // MARK: Classification

    static func classify(header: Data) -> Result {
        guard let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] else {
            return .unknown("Not a valid .safetensors header")
        }
        if let metadata = json["__metadata__"] as? [String: String] {
            for key in ["ss_base_model_version", "modelspec.architecture", "base_model", "ss_sd_model_name"] {
                if let value = metadata[key], let base = LoRABase(metadata: value) { return .known(base) }
            }
        }
        var shapes: [String: [Int]] = [:]
        for (key, value) in json where key != "__metadata__" {
            if let info = value as? [String: Any], let shape = info["shape"] as? [Int] { shapes[key] = shape }
        }
        if let base = classify(shapes: shapes) { return .known(base) }
        return .unknown("No base model in its metadata, and its layers don't match a supported model")
    }

    /// Structural fallback for LoRAs without metadata. Only patterns that identify a
    /// model unambiguously; anything else stays unknown.
    private static func classify(shapes: [String: [Int]]) -> LoRABase? {
        let keys = shapes.keys
        /// Input width of the LoRA's down/A matrices whose key contains `fragment`.
        func inputWidth(_ fragment: String) -> Int? {
            keys.first { $0.contains(fragment) && ($0.contains("lora_A") || $0.contains("lora_down")) }
                .flatMap { shapes[$0]?.last }
        }
        func outputWidth(_ fragment: String) -> Int? {
            keys.first { $0.contains(fragment) && ($0.contains("lora_B") || $0.contains("lora_up")) }
                .flatMap { shapes[$0]?.first }
        }

        // Z-Image: `layers.N.attention.*` (plus noise/context refiners), hidden size 3840.
        if keys.contains(where: { $0.contains("noise_refiner") || $0.contains("context_refiner") })
            || (keys.contains(where: { $0.contains("layers.") && $0.contains(".attention.") }) && inputWidth(".attention.") == 3840) {
            return .zImage
        }
        // MOSS-Image: `layers.N.proj.{q,k,v,o,ffn_up_gate,ffn_down}` (kohya and PEFT alike).
        if keys.contains(where: { $0.contains(".proj.ffn_up_gate.") }) {
            return .mossImage
        }
        // FLUX (BFL layout): double_blocks. FLUX.2 Klein 4B is 3072 wide with an 18432
        // MLP; Klein 9B is 4096 wide; FLUX.1 is 3072 wide with a 12288 MLP.
        if keys.contains(where: { $0.contains("double_blocks") }) {
            switch (inputWidth("double_blocks"), outputWidth("img_mlp.0")) {
            case (4096, _): return .flux2Klein9B
            case (3072, 18432): return .flux2Klein4B
            case (3072, 12288): return .flux1
            default: return nil
            }
        }
        // SD/SDXL (kohya layout): UNet keys. SDXL has a second text encoder (te2/text_encoder_2).
        if keys.contains(where: { $0.hasPrefix("lora_unet_") }) {
            return keys.contains(where: { $0.hasPrefix("lora_te2_") }) ? .sdxl : .sd15
        }
        return nil
    }
}
