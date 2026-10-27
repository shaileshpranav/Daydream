#if DEBUG
import Foundation

/// Headless end-to-end check of download + load + generate, for Debug builds:
///
///   CoreMLImageGen.app/Contents/MacOS/CoreMLImageGen -smokeTest sd15-palettized [-seed 42] [-steps 25]
///
/// Prints timings and the saved PNG path, then exits (status 1 on failure).
@MainActor
enum SmokeTest {
    static func runIfRequested(store: ModelStore, generator: Generator) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "loraTest") {
            Task { exit(await runLoRATest() ? 0 : 1) }
            return
        }
        if let idea = defaults.string(forKey: "enhanceTest") {
            Task { exit(await runEnhance(idea: idea) ? 0 : 1) }
            return
        }
        guard let id = defaults.string(forKey: "smokeTest") else { return }
        Task {
            let ok = await run(id: id, store: store, generator: generator,
                               seed: UInt32(defaults.integer(forKey: "seed")),
                               steps: defaults.integer(forKey: "steps"))
            exit(ok ? 0 : 1)
        }
    }

    /// `-loraTest YES` classifies the Loras folder, a Hugging Face LoRA (header only),
    /// and synthetic metadata-free headers for the shape-based fallback.
    private static func runLoRATest() async -> Bool {
        for url in ModelStore.libraryLoRAs() {
            print("[lora] folder \(url.lastPathComponent): \(LoRAInspector.inspect(file: url))")
        }
        do {
            let (file, result) = try await LoRAInspector.inspect(repo: "renderartist/Technically-Color-Z-Image-Turbo")
            print("[lora] repo renderartist/Technically-Color-Z-Image-Turbo (\(file)): \(result)")
        } catch {
            print("[lora] repo check failed: \(error.localizedDescription)")
        }
        func header(_ tensors: [String: [Int]]) -> Data {
            try! JSONSerialization.data(withJSONObject: tensors.mapValues { ["dtype": "F16", "shape": $0, "data_offsets": [0, 0]] })
        }
        let cases: [(String, [String: [Int]], LoRAInspector.Result)] = [
            ("klein4b", ["diffusion_model.double_blocks.0.img_attn.qkv.lora_A.weight": [16, 3072],
                         "diffusion_model.double_blocks.0.img_mlp.0.lora_B.weight": [18432, 16]], .known(.flux2Klein4B)),
            ("flux1", ["double_blocks.0.img_attn.qkv.lora_A.weight": [16, 3072],
                       "double_blocks.0.img_mlp.0.lora_B.weight": [12288, 16]], .known(.flux1)),
            ("klein9b", ["double_blocks.0.img_attn.qkv.lora_A.weight": [16, 4096]], .known(.flux2Klein9B)),
            ("zimage", ["diffusion_model.layers.0.attention.to_q.lora_A.weight": [16, 3840]], .known(.zImage)),
            ("sdxl", ["lora_unet_down_blocks_0.lora_down.weight": [8, 320], "lora_te2_text_model.lora_down.weight": [8, 1280]], .known(.sdxl)),
            ("sd15", ["lora_unet_down_blocks_0.lora_down.weight": [8, 320]], .known(.sd15)),
            ("qwen-no-metadata", ["transformer_blocks.0.attn.to_q.lora_A.weight": [16, 3072]], .unknown("")),
        ]
        var ok = true
        for (name, tensors, expected) in cases {
            let got = LoRAInspector.classify(header: header(tensors))
            let pass = switch (got, expected) {
            case (.unknown, .unknown): true
            default: got == expected
            }
            ok = ok && pass
            print("[lora] synthetic \(name): \(got) \(pass ? "✓" : "✗ expected \(expected)")")
        }
        for value in ["flux2_klein_4b", "sdxl_base_v1-0", "stable-diffusion-xl-v1-base/lora", "flux-1-dev/lora",
                      "z_image_turbo", "qwen_image_2_1", "qwen-image", "sd_v1"] {
            print("[lora] metadata \"\(value)\" -> \(LoRABase(metadata: value).map(\.label) ?? "nil")")
        }
        return ok
    }

    /// `-enhanceTest "a fox in snow"` prints the enhancer's output for an SD 1.x and an SDXL model.
    private static func runEnhance(idea: String) async -> Bool {
        print("[enhance] availability: \(PromptEnhancer.availability)")
        for kind in [ModelKind.sd, .sdxl] {
            let model = InstalledModel(id: "test", name: "test", kind: kind, computeUnits: .all, resolution: 512)
            let start = Date()
            do {
                let result = try await PromptEnhancer.enhance(prompt: idea, negativePrompt: "", for: model)
                print("[enhance] \(kind.label) (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
                print("[enhance]   prompt:   \(result.prompt)")
                print("[enhance]   negative: \(result.negativePrompt)")
            } catch {
                print("[enhance] \(kind.label) failed: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private static func run(id: String, store: ModelStore, generator: Generator, seed: UInt32, steps: Int) async -> Bool {
        func log(_ s: String) { print("[smoke] \(s)"); fflush(stdout) }

        if store.model(id: id) == nil {
            guard let entry = ModelCatalog.entries.first(where: { $0.id == id }) else {
                log("unknown catalog id \(id)"); return false
            }
            log("downloading \(entry.name) (~\(entry.approxGB) GB)")
            let start = Date()
            store.download(entry)
            var lastPct = -10
            while store.downloads[id] != nil {
                let pct = Int((store.downloads[id]?.fraction ?? 0) * 100)
                if pct >= lastPct + 10 { log("download \(pct)%"); lastPct = pct }
                try? await Task.sleep(for: .seconds(1))
            }
            if let error = store.lastError { log(error); return false }
            log("downloaded in \(Int(Date().timeIntervalSince(start))) s")
        }
        guard let model = store.model(id: id) else { log("model not installed after download"); return false }

        if model.kind == .mlx, !MLXRuntime.isInstalled {
            log("installing MLX runtime (\(MLXRuntime.package))")
            let runtime = MLXRuntime()
            runtime.install()
            while case .installing = runtime.status { try? await Task.sleep(for: .seconds(1)) }
            if case .failed(let message) = runtime.status { log("runtime install failed: \(message)"); return false }
            log("MLX runtime installed")
        }

        var request = GenerationRequest(prompt: "a red fox standing in fresh snow at dawn, soft morning light, photo")
        request.seed = seed == 0 ? 42 : seed
        request.steps = steps == 0 ? (model.defaults?.steps ?? 25) : steps
        request.guidance = model.defaults?.guidance ?? request.guidance
        if model.kind == .mlx, let size = UserDefaults.standard.string(forKey: "base").flatMap(Int.init) {
            // -base 512 for a quicker MLX check
            var smaller = model
            smaller = InstalledModel(id: model.id, name: model.name, kind: model.kind, computeUnits: model.computeUnits,
                                     resolution: size, loras: model.loras, mlxFamily: model.mlxFamily,
                                     defaults: model.defaults, folder: model.folder)
            return await generateTwice(model: smaller, request: request, generator: generator, log: log)
        }
        return await generateTwice(model: model, request: request, generator: generator, log: log)
    }

    private static func generateTwice(model: InstalledModel, request: GenerationRequest, generator: Generator, log: (String) -> Void) async -> Bool {

        for run in 1...2 {
            let start = Date()
            await generator.generate(model: model, request: request, previewEvery: 0)
            if let error = generator.lastError { log("error: \(error)"); return false }
            guard let record = generator.lastRecord else { log("no record"); return false }
            let compute = model.kind == .mlx ? "MLX GPU" : model.computeUnits.label
            log("run \(run): \(String(format: "%.1f", Date().timeIntervalSince(start))) s total (incl. load), \(String(format: "%.1f", record.seconds)) s generation, \(compute), \(request.steps) steps")
            log("saved \(ImageSaver.folder.appending(path: record.fileName).path)")
        }
        generator.unloadModel()
        return true
    }
}
#endif
