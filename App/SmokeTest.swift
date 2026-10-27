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
