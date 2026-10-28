#if DEBUG
import CoreGraphics
import Foundation
import ImageIO

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

/// Headless end-to-end check of download + load + generate, for Debug builds:
///
///   CoreMLImageGen.app/Contents/MacOS/CoreMLImageGen -smokeTest sd15-palettized [-seed 42] [-steps 25]
///
/// Prints timings and the saved PNG path, then exits (status 1 on failure).
@MainActor
enum SmokeTest {
    static func runIfRequested(store: ModelStore, generator: Generator, queue: GenerationQueue) {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "previewTest") {
            Task { exit(await runPreviewTest(id: id, out: defaults.string(forKey: "out"), store: store, generator: generator) ? 0 : 1) }
            return
        }
        if let id = defaults.string(forKey: "precisionTest") {
            Task { exit(await runPrecisionTest(id: id, store: store, generator: generator) ? 0 : 1) }
            return
        }
        if let id = defaults.string(forKey: "preloadTest") {
            Task { exit(await runPreloadTest(id: id, store: store, generator: generator) ? 0 : 1) }
            return
        }
        if defaults.bool(forKey: "managerTest") {
            Task { exit(await runManagerTest(store: store) ? 0 : 1) }
            return
        }
        if let id = defaults.string(forKey: "img2imgTest"), let start = defaults.string(forKey: "start") {
            Task { exit(await runImg2ImgTest(id: id, start: start, store: store, generator: generator) ? 0 : 1) }
            return
        }
        if let id = defaults.string(forKey: "queueTest") {
            Task { exit(await runQueueTest(id: id, store: store, generator: generator, queue: queue) ? 0 : 1) }
            return
        }
        if defaults.bool(forKey: "loraTest") {
            Task { exit(await runLoRATest() ? 0 : 1) }
            return
        }
        if defaults.bool(forKey: "mossTest") {
            Task { exit(await runMOSSTest(store: store, generator: generator) ? 0 : 1) }
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

    /// `-previewTest <mlx model id> [-out dir]`: three images with one prompt.
    /// 1 (previews off, seed 21) encodes the prompt; 2 (off, seed 22) should reuse it;
    /// 3 (previews on, seed 22) measures preview cost, must match 2 pixel for pixel, and
    /// saves its previews to `out`.
    private static func runPreviewTest(id: String, out: String?, store: ModelStore, generator: Generator) async -> Bool {
        func log(_ s: String) { print("[preview] \(s)"); fflush(stdout) }
        guard var model = store.model(id: id) else { log("\(id) isn't installed"); return false }
        let base = UserDefaults.standard.integer(forKey: "base")
        if base > 0 { model.resolution = base }  // -base 512 for a quicker check
        var request = GenerationRequest(prompt: "a lighthouse on a rocky coast at sunset, waves crashing, dramatic clouds")
        request.steps = model.recommended.steps
        request.guidance = model.recommended.guidance

        var results: [(seconds: Double, image: CGImage)] = []
        var previews: [CGImage] = []
        for (seed, previewEvery) in [(UInt32(21), 0), (22, 0), (22, 5)] {
            request.seed = seed
            let watcher = Task { @MainActor in
                var last: CGImage?
                while !Task.isCancelled {
                    if let p = generator.preview, p !== last { previews.append(p); last = p }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            let outcome = await generator.generate(model: model, request: request, previewEvery: previewEvery)
            watcher.cancel()
            guard case .saved(let record) = outcome, let image = generator.lastImage else { log("\(outcome)"); return false }
            results.append((record.seconds, image))
            log("seed \(seed), previews \(previewEvery > 0 ? "on" : "off"): \(String(format: "%.1f", record.seconds)) s")
        }
        generator.unloadModel()

        let saved = results[0].seconds - results[1].seconds
        let overhead = results[2].seconds - results[1].seconds
        let samePixels = psnr(results[1].image, results[2].image).isInfinite
        log("prompt reuse saved \(String(format: "%.1f", saved)) s per image")
        log("previews: \(previews.count) shown, adding \(String(format: "%.1f", overhead)) s (\(String(format: "%.0f", 100 * overhead / results[1].seconds))%)")
        log("final image with previews identical to without: \(samePixels ? "yes" : "NO")")
        if let out {
            for (i, p) in previews.enumerated() {
                let url = URL(filePath: out).appending(path: "preview-\(i + 1).png")
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, p, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
            log("saved previews to \(out)")
        }
        let ok = samePixels && !previews.isEmpty
        log(ok ? "PASS" : "FAIL")
        return ok
    }

    /// Downloads a catalog model if it isn't installed yet.
    private static func ensureInstalled(id: String, store: ModelStore, log: (String) -> Void) async -> InstalledModel? {
        if let model = store.model(id: id) { return model }
        guard let entry = ModelCatalog.entries.first(where: { $0.id == id }) else { log("unknown catalog id \(id)"); return nil }
        log("downloading \(entry.name) (~\(entry.approxGB) GB)")
        let start = Date()
        store.download(entry)
        var lastPct = -25
        while store.downloads[id] != nil {
            let pct = Int((store.downloads[id]?.fraction ?? 0) * 100)
            if pct >= lastPct + 25 { log("download \(pct)%"); lastPct = pct }
            try? await Task.sleep(for: .seconds(1))
        }
        if let error = store.lastError { log(error); return nil }
        log("downloaded in \(Int(Date().timeIntervalSince(start))) s")
        return store.model(id: id)
    }

    /// `-mossTest YES [-full YES]`: installs MOSS-Image SFT q4 and its Fast mode LoRA if needed,
    /// then times two Fast mode pictures (8 steps, guidance 1). With -full it also times the
    /// 50-step default with and without step reuse and compares the two pictures.
    private static func runMOSSTest(store: ModelStore, generator: Generator) async -> Bool {
        func log(_ s: String) { print("[moss] \(s)"); fflush(stdout) }
        guard let model = await ensureInstalled(id: "mlx-moss-image-sft-q4", store: store, log: log),
              let fast = model.fastLoRA else { return false }
        if !fast.isDownloaded {
            log("downloading \(fast.repo) (~\(fast.approxGB) GB)")
            let start = Date()
            var lastPct = -25
            do {
                _ = try await LoRALibrary().download(repo: fast.repo) { fraction in
                    let pct = Int(fraction * 100)
                    if pct >= lastPct + 25 { log("download \(pct)%"); lastPct = pct }
                }
            } catch {
                log("LoRA download failed: \(error.localizedDescription)"); return false
            }
            guard fast.isDownloaded else { log("download didn't produce \(fast.localURL.path)"); return false }
            log("downloaded in \(Int(Date().timeIntervalSince(start))) s")
        }

        var request = GenerationRequest(prompt: "A wooden signpost in a snowy pine forest at dawn. The sign is painted with the words \"FAST MODE\" in white letters. Soft morning light, photo")
        request.seed = 42
        func generate(_ label: String, _ request: GenerationRequest) async -> CGImage? {
            let start = Date()
            await generator.generate(model: model, request: request, previewEvery: 0)
            if let error = generator.lastError { log("\(label): error: \(error)"); return nil }
            guard let record = generator.lastRecord else { log("\(label): no record"); return nil }
            let reuse = record.request.stepCacheRatio.map { ", step reuse \($0)" } ?? ""
            log("\(label): \(String(format: "%.1f", Date().timeIntervalSince(start))) s total (incl. load), "
                + "\(String(format: "%.1f", record.seconds)) s generation, \(request.steps) steps, guidance \(request.guidance)\(reuse)")
            log("saved \(ImageSaver.folder.appending(path: record.fileName).path)")
            return generator.lastImage
        }

        var fastRequest = request
        fastRequest.loras = [LoRARef(source: fast.localURL.path, scale: 1, base: model.loraBase)]
        fastRequest.steps = fast.steps
        fastRequest.guidance = fast.guidance
        for run in 1...2 {
            guard await generate("fast run \(run)", fastRequest) != nil else { return false }
        }
        guard UserDefaults.standard.bool(forKey: "full") else {
            generator.unloadModel()
            return true
        }

        var slowRequest = request
        slowRequest.steps = model.recommended.steps
        slowRequest.guidance = model.recommended.guidance
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: MLXBackend.stepCacheKey)
        defer { defaults.set(original, forKey: MLXBackend.stepCacheKey) }
        defaults.set(true, forKey: MLXBackend.stepCacheKey)
        guard let reused = await generate("50 steps, step reuse on", slowRequest) else { return false }
        defaults.set(false, forKey: MLXBackend.stepCacheKey)
        guard let full = await generate("50 steps, step reuse off", slowRequest) else { return false }
        log("step reuse vs none, same seed: PSNR \(String(format: "%.1f", psnr(reused, full))) dB")
        generator.unloadModel()
        return true
    }

    /// Mean-squared-error PSNR (dB) between two images of the same size; higher = closer.
    private static func psnr(_ a: CGImage, _ b: CGImage) -> Double {
        let w = a.width, h = a.height
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        let p = pixels(a), q = pixels(b)
        var sum = 0.0
        for i in stride(from: 0, to: p.count, by: 4) {
            for c in 0..<3 { let d = Double(Int(p[i + c]) - Int(q[i + c])); sum += d * d }
        }
        let mse = sum / Double(w * h * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    /// `-precisionTest <model id>` generates the same seed with 32-bit and 16-bit GPU
    /// accumulation (each after a warm-up image) and reports speed and PSNR between them.
    private static func runPrecisionTest(id: String, store: ModelStore, generator: Generator) async -> Bool {
        func log(_ s: String) { print("[precision] \(s)"); fflush(stdout) }
        guard let model = await ensureInstalled(id: id, store: store, log: log) else { return false }
        let defaults = UserDefaults.standard
        // Put back exactly what was there: an unset key must stay unset so the registered
        // default (on) keeps applying, rather than being pinned to an explicit value.
        let original = defaults.object(forKey: StableDiffusionBackend.lowPrecisionKey)
        defer { defaults.set(original, forKey: StableDiffusionBackend.lowPrecisionKey) }

        var request = GenerationRequest(prompt: "portrait of an old fisherman with a weathered face, harbour at dusk, detailed photo")
        request.seed = 5
        request.steps = Int(defaults.integer(forKey: "steps")).nonZero ?? 20
        request.guidance = 7.5
        var results: [(label: String, seconds: Double, image: CGImage)] = []
        for low in [false, true] {
            defaults.set(low, forKey: StableDiffusionBackend.lowPrecisionKey)
            let label = low ? "16-bit accumulation" : "32-bit accumulation"
            var warm = request
            warm.seed = 99
            let loadStart = Date()
            _ = await generator.generate(model: model, request: warm, previewEvery: 0)  // load + warm-up
            log("\(label): load + warm-up \(String(format: "%.0f", Date().timeIntervalSince(loadStart))) s")
            let outcome = await generator.generate(model: model, request: request, previewEvery: 0)
            guard case .saved(let record) = outcome, let image = generator.lastImage else {
                log("\(label): \(outcome)"); return false
            }
            results.append((label, record.seconds, image))
            log("\(label): \(String(format: "%.1f", record.seconds)) s for \(request.steps) steps (\(String(format: "%.2f", record.seconds / Double(request.steps))) s/step), saved \(record.fileName)")
        }
        generator.unloadModel()
        let speedup = results[0].seconds / results[1].seconds
        let db = psnr(results[0].image, results[1].image)
        log("speed: 16-bit is \(String(format: "%.2f", speedup))× the 32-bit speed")
        log("difference: PSNR \(db.isInfinite ? "∞ (identical)" : String(format: "%.1f dB", db)) (above ~35 dB is hard to see; above ~40 dB is practically identical)")
        return true
    }

    /// `-preloadTest <model id>` starts a preload and immediately asks for an image: the
    /// generate must wait for the preload (not fail) and the model must load only once.
    private static func runPreloadTest(id: String, store: ModelStore, generator: Generator) async -> Bool {
        func log(_ s: String) { print("[preload] \(s)"); fflush(stdout) }
        guard let model = store.model(id: id) else { log("\(id) isn't installed"); return false }
        generator.unloadModel()
        var request = GenerationRequest(prompt: "a small wooden cabin in a pine forest, morning fog")
        request.steps = model.recommended.steps
        request.guidance = model.recommended.guidance
        request.seed = 11

        var loads = 0, wasLoading = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if case .loading = generator.phase { if !wasLoading { loads += 1 }; wasLoading = true } else { wasLoading = false }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let start = Date()
        let preload = Task { await generator.preload(model: model, request: request) }
        try? await Task.sleep(for: .milliseconds(200))  // generate arrives mid-preload
        let outcome = await generator.generate(model: model, request: request, previewEvery: 0)
        await preload.value
        watcher.cancel()
        log("outcome: \(outcome), model loads: \(loads), total \(String(format: "%.1f", Date().timeIntervalSince(start))) s")

        // A second preload of the loaded model must be a no-op.
        let again = Date()
        await generator.preload(model: model, request: request)
        let noop = Date().timeIntervalSince(again)
        log("preload of the already-loaded model took \(String(format: "%.3f", noop)) s")
        generator.unloadModel()

        let ok: Bool = { if case .saved = outcome { return loads == 1 && noop < 0.5 }; return false }()
        log(ok ? "PASS" : "FAIL")
        return ok
    }

    /// `-managerTest YES` checks family detection, model edits and the LoRA library.
    private static func runManagerTest(store: ModelStore) async -> Bool {
        func log(_ s: String) { print("[manager] \(s)"); fflush(stdout) }
        var ok = true
        let repos: [(String, String?)] = [
            ("mflux-community/z-image-turbo-mflux-q4", "z-image-turbo"),
            ("mflux-community/z-image-base-mflux-q8", "z-image"),
            ("mflux-community/flux2-klein-9b-mflux-q4", "flux2-klein-9b"),
            ("mflux-community/flux2-klein-4b-mflux-q6", "flux2-klein-4b"),
            ("mflux-community/flux2-klein-9b-kv-mflux-q4", nil),
            ("mflux-community/flux-2-klein-base-4b-mflux-q4", nil),
            ("mflux-community/qwen-image-2-1-turbo-mflux-q4", "qwen-image-2.1-turbo"),
            ("mflux-community/qwen-image-2-1-mflux-q5", "qwen-image-2.1"),
            ("mflux-community/qwen-image-edit-2511-mflux-q4", nil),
            ("filipstrand/Z-Image-Turbo-mflux-4bit", "z-image-turbo"),
            ("mflux-community/moss-image-sft-mflux-q4", "moss-image"),
            ("mflux-community/moss-image-base-mflux-q8", "moss-image-base"),
            ("chinoll/Moss-Image-Edit", nil),
            ("mflux-community/flux-3-image-klein-mflux-q4", "flux3-klein"),
            ("mflux-community/flux-3-image-klein-base-mflux-q4", nil),
            ("mflux-community/iris-3b-turbo-mflux-q4", "iris-3b-turbo"),
            ("mflux-community/iris-3b-mflux-q8", nil),
            ("mflux-community/anima-turbo-mflux-q4", "anima-turbo"),
            ("mflux-community/anima-aesthetic-mflux-q5", "anima-aesthetic"),
            ("mflux-community/anima-base-mflux-q8", "anima-base"),
            ("mflux-community/ernie-image-turbo-mflux-q4", "ernie-image-turbo"),
            ("mflux-community/ernie-image-base-mflux-q3", "ernie-image"),
            ("cagliostrolab/animagine-xl-4.0", nil),
        ]
        for (repo, expected) in repos {
            let got = MLXFamilies.detect(repo: repo)?.id
            let pass = got == expected
            ok = ok && pass
            log("detect \(repo) -> \(got ?? "nil") \(pass ? "✓" : "✗ expected \(expected ?? "nil")") quant=\(MLXFamilies.quantization(repo: repo) ?? "-")")
        }
        // A real repo listing, as Install does before downloading (no download here).
        do {
            let files = try await HuggingFace.listFiles(repo: "mflux-community/flux2-klein-9b-mflux-q4", prefix: "")
            let gb = Double(files.reduce(Int64(0)) { $0 + $1.size }) / 1e9
            let estimate = MemoryEstimate.gigabytes(weightsGB: gb, kind: .mlx, resolution: 1024)
            log("flux2-klein-9b q4: \(String(format: "%.1f", gb)) GB, est. \(String(format: "%.1f", estimate)) GB → \(MemoryEstimate.fit(estimate).label)")
        } catch {
            log("listing failed: \(error.localizedDescription)"); ok = false
        }
        // Rename + defaults round trip through model.json.
        if var model = store.installed.first {
            let original = model
            model.name = original.name + " (renamed)"
            model.defaults = ModelDefaults(steps: 7, guidance: 2.5, supportsNegativePrompt: original.defaults?.supportsNegativePrompt)
            store.update(model)
            let reread = store.model(id: model.id)
            let pass = reread?.name == model.name && reread?.defaults?.steps == 7
            ok = ok && pass
            log("rename/defaults round trip: \(pass ? "✓" : "✗")")
            store.update(original)
            log("restored: \(store.model(id: original.id)?.name == original.name && store.model(id: original.id)?.defaults == original.defaults ? "✓" : "✗")")
        }
        // MOSS-Image Fast mode: the LoRA the library would download (header only) is the file
        // Fast mode looks for, at the path LoRALibrary.download writes.
        if let fast = MLXFamilies.family(id: "moss-image")?.fastLoRA {
            do {
                let (file, _, result) = try await LoRAInspector.inspect(repo: fast.repo)
                let folder = ModelStore.lorasFolder.appending(path: fast.repo.replacingOccurrences(of: "/", with: "__"))
                let pass = file == fast.file && result == .known(.mossImage)
                    && folder.appending(path: file).path == fast.localURL.path
                ok = ok && pass
                log("fast mode LoRA: \(file) \(result), at \(fast.localURL.path) \(pass ? "✓" : "✗")")
            } catch {
                log("fast mode LoRA check failed: \(error.localizedDescription)"); ok = false
            }
            let name = LoRARef(source: fast.localURL.path).name
            ok = ok && name == "MOSS-Image-SFT-8-steps-dmd"
            log("fast mode LoRA name: \(name) \(name == "MOSS-Image-SFT-8-steps-dmd" ? "✓" : "✗")")
        }
        // Saved settings: older records decode without stepCacheRatio; new ones keep it.
        do {
            let old = try JSONDecoder().decode(GenerationRequest.self, from: Data(#"{"prompt":"x","negativePrompt":"","steps":9,"guidance":0,"seed":1,"scheduler":"DPM-Solver++"}"#.utf8))
            var new = GenerationRequest()
            new.stepCacheRatio = 0.25
            let back = try JSONDecoder().decode(GenerationRequest.self, from: JSONEncoder().encode(new))
            let pass = old.stepCacheRatio == nil && back.stepCacheRatio == 0.25
            ok = ok && pass
            log("stepCacheRatio in saved settings: \(pass ? "✓" : "✗")")
        } catch {
            log("settings decode failed: \(error.localizedDescription)"); ok = false
        }
        let library = LoRALibrary()
        for item in library.items {
            log("lora \(item.name): \(item.base?.label ?? "unknown"), \(item.trainingSteps.map { "\($0) steps" } ?? "-"), suggestions \(item.suggestedTriggers)")
        }
        log(ok ? "PASS" : "FAIL")
        return ok
    }

    /// `-img2imgTest <model id> -start <image path>` generates from the start image at
    /// change 0.3 and 0.9 and checks the low-change result stays closer to the start.
    private static func runImg2ImgTest(id: String, start: String, store: ModelStore, generator: Generator) async -> Bool {
        func log(_ s: String) { print("[img2img] \(s)"); fflush(stdout) }
        guard let model = store.model(id: id) else { log("\(id) isn't installed"); return false }
        guard let startPath = try? StartImages.importImage(URL(filePath: start)),
              let startImage = StartImages.load(startPath) else { log("can't read \(start)"); return false }

        /// Mean absolute RGB difference (0–255) after scaling both to 64×64.
        func distance(_ a: CGImage, _ b: CGImage) -> Double {
            func pixels(_ image: CGImage) -> [UInt8] {
                var data = [UInt8](repeating: 0, count: 64 * 64 * 4)
                let ctx = CGContext(data: &data, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(StartImages.fill(image, width: 64, height: 64)!, in: CGRect(x: 0, y: 0, width: 64, height: 64))
                return data
            }
            let p = pixels(a), q = pixels(b)
            var sum = 0
            for i in stride(from: 0, to: p.count, by: 4) {
                for c in 0..<3 { sum += abs(Int(p[i + c]) - Int(q[i + c])) }
            }
            return Double(sum) / Double(64 * 64 * 3)
        }

        var request = GenerationRequest(prompt: "a fox in snow, oil painting with thick visible brush strokes")
        request.seed = 3
        request.steps = model.recommended.steps
        request.guidance = model.recommended.guidance
        request.startImage = startPath
        if model.kind == .mlx { request.aspect = StartImages.closestAspect(to: startPath) }

        var distances: [Double] = []
        for change in [0.3, 0.9] {
            request.change = change
            let outcome = await generator.generate(model: model, request: request, previewEvery: 0)
            guard case .saved(let record) = outcome, let image = generator.lastImage else {
                log("change \(change): \(outcome)"); return false
            }
            let d = distance(startImage, image)
            distances.append(d)
            log("change \(change): distance from start \(String(format: "%.1f", d)), \(String(format: "%.1f", record.seconds)) s, \(image.width)×\(image.height), saved \(record.fileName)")
        }
        generator.unloadModel()
        let ok = distances[0] < distances[1]
        log(ok ? "PASS (low change stays closer to the start image)" : "FAIL")
        return ok
    }

    /// `-queueTest sd15-palettized` queues a batch of 3 (10 steps each), cancels the
    /// middle job after its third step, and checks done / cancelled / done with seeds 7, 8, 9.
    private static func runQueueTest(id: String, store: ModelStore, generator: Generator, queue: GenerationQueue) async -> Bool {
        func log(_ s: String) { print("[queue] \(s)"); fflush(stdout) }
        guard let model = store.model(id: id) else { log("\(id) isn't installed"); return false }
        var request = GenerationRequest(prompt: "a lighthouse on a cliff at night, long exposure photo")
        request.seed = 7
        request.steps = 10
        let start = Date()
        queue.enqueue(model: model, request: request, count: 3, previewEvery: 0)
        log("queued \(queue.jobs.count) jobs, seeds \(queue.jobs.map(\.request.seed))")

        var cancelledMiddle = false
        var loads = 0, wasLoading = false
        while queue.isRunning || queue.pendingCount > 0 {
            if case .loading = generator.phase { if !wasLoading { loads += 1 }; wasLoading = true } else { wasLoading = false }
            if !cancelledMiddle, queue.jobs[1].state == .running, case .generating(let step, _) = generator.phase, step >= 3 {
                log("cancelling job 2 at step \(step)")
                queue.cancelCurrent()
                cancelledMiddle = true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let states = queue.jobs.map { job -> String in
            switch job.state {
            case .done(let r): "done(seed \(r.request.seed), \(String(format: "%.1f", r.seconds)) s)"
            case .cancelled: "cancelled"
            case .failed(let m): "failed(\(m))"
            default: "\(job.state)"
            }
        }
        log("states: \(states.joined(separator: ", "))")
        log("model loads: \(loads), total \(String(format: "%.0f", Date().timeIntervalSince(start))) s")
        let ok: Bool = {
            guard queue.jobs.count == 3, case .done(let a) = queue.jobs[0].state, queue.jobs[1].state == .cancelled,
                  case .done(let c) = queue.jobs[2].state else { return false }
            return a.request.seed == 7 && c.request.seed == 9 && loads <= 1
        }()
        log(ok ? "PASS" : "FAIL")
        return ok
    }

    /// `-loraTest YES` classifies the Loras folder, a Hugging Face LoRA (header only),
    /// and synthetic metadata-free headers for the shape-based fallback.
    private static func runLoRATest() async -> Bool {
        for url in ModelStore.libraryLoRAs() {
            print("[lora] folder \(url.lastPathComponent): \(LoRAInspector.inspect(file: url))")
        }
        // The second repo also ships helper weights and a full transformer: the LoRA must be
        // picked by name and referenced as repo:file.
        for repo in ["renderartist/Technically-Color-Z-Image-Turbo", "lodestones/MOSS-Image-SFT-8-steps-dmd"] {
            do {
                let (file, reference, result) = try await LoRAInspector.inspect(repo: repo)
                print("[lora] repo \(repo) (\(file), loads as \(reference)): \(result)")
            } catch {
                print("[lora] repo check failed: \(error.localizedDescription)")
            }
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
            ("moss", ["diffusion_model.layers.0.proj.ffn_up_gate.lora_down.weight": [128, 3072],
                      "diffusion_model.layers.0.proj.q.lora_up.weight": [3072, 128]], .known(.mossImage)),
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
                      "z_image_turbo", "qwen_image_2_1", "qwen-image", "sd_v1",
                      "flux-3-image-klein", "anima", "animagine-xl-3.1", "ernie_image", "moss_image"] {
            print("[lora] metadata \"\(value)\" -> \(LoRABase(metadata: value).map(\.label) ?? "nil")")
        }
        return ok
    }

    /// `-enhanceTest "a fox in snow"` prints the enhancer's output for each model kind.
    /// Add `-promptEnhancerEngine mlx` to test the MLX language model instead of Apple Intelligence.
    private static func runEnhance(idea: String) async -> Bool {
        print("[enhance] engine: \(PromptEnhancer.engineDescription), availability: \(PromptEnhancer.availability)")
        for model in PromptModel.all {
            print("[enhance] MLX model \(model.id): \(model.size), \(model.source), \(model.folder?.path ?? "not downloaded")")
        }
        for kind in [ModelKind.sd, .sdxl, .mlx] {
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
            log("installing MLX runtime (\(MLXRuntime.packageSummary))")
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
