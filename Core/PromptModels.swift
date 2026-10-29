import Foundation
import Observation

/// An instruct language model the prompt enhancer can run with mlx-lm instead of Apple
/// Intelligence. Three kinds: the built-in catalog, any Hugging Face repo the user added
/// (both downloaded to ~/Library/Application Support/CoreMLImageGen/PromptModels/<id>/), and
/// MLX models already in the Hugging Face cache (~/.cache/huggingface/hub), used in place.
struct PromptModel: Identifiable, Hashable {
    enum Source: Hashable {
        case catalog
        case added
        case huggingFaceCache
    }

    let id: String
    let name: String
    let repo: String
    let size: String
    let notes: String
    var source: Source = .catalog

    static let catalog = [
        PromptModel(id: "qwen3-4b-instruct-2507-4bit", name: "Qwen3 4B Instruct", repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit",
                    size: "2.3 GB", notes: "Fast and reliable. Recommended."),
        PromptModel(id: "qwen3.5-2b-4bit", name: "Qwen3.5 2B", repo: "mlx-community/Qwen3.5-2B-4bit",
                    size: "1.8 GB", notes: "Smallest and fastest. Less imaginative."),
        PromptModel(id: "llama-3.2-3b-instruct-4bit", name: "Llama 3.2 3B Instruct", repo: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                    size: "1.8 GB", notes: "Small and quick."),
        PromptModel(id: "qwen3.5-4b-4bit", name: "Qwen3.5 4B", repo: "mlx-community/Qwen3.5-4B-4bit",
                    size: "3.1 GB", notes: "Newer, a little slower."),
        PromptModel(id: "gemma-3-4b-it-qat-4bit", name: "Gemma 3 4B", repo: "mlx-community/gemma-3-4b-it-qat-4bit",
                    size: "3.0 GB", notes: "Google's small model. Vivid descriptions."),
        PromptModel(id: "qwen3.5-9b-mlx-4bit", name: "Qwen3.5 9B", repo: "mlx-community/Qwen3.5-9B-MLX-4bit",
                    size: "6.0 GB", notes: "Best rewrites, slowest. Uses about 6 GB while loaded, so best with 24 GB of memory or more."),
    ]
    static let defaultID = catalog[0].id

    /// The catalog, then added repos, then models found in the Hugging Face cache. Reads the
    /// disk each time, so models added outside the app show up.
    static var all: [PromptModel] {
        let fm = FileManager.default
        let catalogRepos = Set(catalog.map(\.repo))
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let added = dirs.compactMap { dir -> PromptModel? in
            guard let data = try? Data(contentsOf: dir.appending(path: sourceFile)),
                  let info = try? JSONDecoder().decode(AddedInfo.self, from: data),
                  !catalogRepos.contains(info.repo)
            else { return nil }
            return PromptModel(id: dir.lastPathComponent, name: info.repo.split(separator: "/").last.map(String.init) ?? info.repo,
                               repo: info.repo, size: info.size, notes: "Added from \(info.repo).", source: .added)
        }
        let known = catalogRepos.union(added.map(\.repo))
        let cached = cachedRepos().filter { !known.contains($0.repo) }.map { repo, folder in
            PromptModel(id: "hf-cache:" + repo, name: repo.split(separator: "/").last.map(String.init) ?? repo,
                        repo: repo, size: ByteCountFormatter.string(fromByteCount: snapshotSize(folder), countStyle: .file),
                        notes: "Found in the Hugging Face cache (\(repo)).", source: .huggingFaceCache)
        }
        return catalog + added.sorted { $0.name < $1.name } + cached.sorted { $0.name < $1.name }
    }

    static func named(_ id: String?) -> PromptModel {
        let models = all
        return models.first { $0.id == id } ?? models[0]
    }

    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CoreMLImageGen/PromptModels", directoryHint: .isDirectory)
    }()

    static let sourceFile = "prompt-model.json"

    struct AddedInfo: Codable {
        var repo: String
        var size: String
    }

    /// The weights: the app's own download if there is one, else the Hugging Face cache's copy.
    var folder: URL? {
        let own = Self.root.appending(path: id, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: own.appending(path: "config.json").path) { return own }
        return Self.cachedFolder(repo: repo)
    }

    /// Downloads land in a staging folder first, so a folder with config.json is complete.
    var isInstalled: Bool { folder != nil }

    /// True when the weights are in the Hugging Face cache rather than the app's folder,
    /// so the app doesn't offer to delete them.
    var usesHuggingFaceCache: Bool {
        !FileManager.default.fileExists(atPath: Self.root.appending(path: id).appending(path: "config.json").path)
            && Self.cachedFolder(repo: repo) != nil
    }

    // MARK: Hugging Face cache

    private static var hubCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["HF_HUB_CACHE"] { return URL(filePath: path) }
        if let home = env["HF_HOME"] { return URL(filePath: home).appending(path: "hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }

    /// The newest complete snapshot of `repo` in the cache: a config.json and weights.
    static func cachedFolder(repo: String) -> URL? {
        let snapshots = hubCache.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appending(path: "snapshots")
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return dirs
            .filter { dir in
                fm.fileExists(atPath: dir.appending(path: "config.json").path)
                    && ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".safetensors") }
            }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// A snapshot's files are symlinks into the cache's blob store, so sizes come from their targets.
    private static func snapshotSize(_ folder: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { total, file in
            let size = try? file.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]).fileSize
            return total + Int64(size ?? 0)
        }
    }

    /// Cached repos that look like MLX language models: quantized by MLX (a `quantization`
    /// entry in config.json) with a causal-LM or chat architecture. Image models, raw
    /// PyTorch checkpoints and datasets don't qualify.
    private static func cachedRepos() -> [(repo: String, folder: URL)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: hubCache.path)) ?? []
        return dirs.compactMap { name in
            guard name.hasPrefix("models--") else { return nil }
            let repo = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
            guard let folder = cachedFolder(repo: repo),
                  let data = try? Data(contentsOf: folder.appending(path: "config.json")),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  config["quantization"] != nil,
                  let architectures = config["architectures"] as? [String],
                  architectures.contains(where: { $0.hasSuffix("ForCausalLM") || $0.hasSuffix("ForConditionalGeneration") })
            else { return nil }
            return (repo, folder)
        }
    }
}

/// Downloads and deletes prompt models for Settings.
@MainActor
@Observable
final class PromptModelStore {
    private(set) var downloads: [String: Double] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var lastError: String?
    /// Bumped on install/delete so views re-read `PromptModel.isInstalled`.
    private(set) var revision = 0

    func download(_ model: PromptModel) {
        guard tasks[model.id] == nil, !model.isInstalled else { return }
        lastError = nil
        downloads[model.id] = 0
        tasks[model.id] = Task {
            do {
                try await performDownload(model)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                lastError = "\(model.name): \(error.localizedDescription)"
            }
            downloads[model.id] = nil
            tasks[model.id] = nil
            revision += 1
        }
    }

    func cancel(_ model: PromptModel) {
        tasks[model.id]?.cancel()
    }

    /// Only the app's own downloads are deleted; the Hugging Face cache is left alone.
    func delete(_ model: PromptModel) {
        MLXPromptRewriter.shared.unload()
        try? FileManager.default.removeItem(at: PromptModel.root.appending(path: model.id))
        revision += 1
    }

    /// Adds any Hugging Face repo with MLX weights (e.g. `mlx-community/Phi-4-mini-instruct-4bit`)
    /// and starts downloading it. Returns the new model's id.
    func add(repo: String) async throws -> String {
        let repo = repo.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "https://huggingface.co/", with: "")
        guard repo.split(separator: "/").count == 2 else {
            throw RuntimeError("Enter a Hugging Face repo like mlx-community/Phi-4-mini-instruct-4bit.")
        }
        if let existing = PromptModel.all.first(where: { $0.repo.lowercased() == repo.lowercased() }) {
            return existing.id
        }
        let files = try await HuggingFace.listFiles(repo: repo, prefix: "")
        guard files.contains(where: { $0.path == "config.json" }),
              files.contains(where: { $0.path.hasSuffix(".safetensors") })
        else {
            throw RuntimeError("\(repo) has no config.json and .safetensors weights. Look for an MLX version (mlx-community/…).")
        }
        let id = repo.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" }
        let model = PromptModel(id: String(id), name: repo, repo: repo,
                                size: ByteCountFormatter.string(fromByteCount: files.reduce(0) { $0 + $1.size }, countStyle: .file),
                                notes: "", source: .added)
        download(model)
        return model.id
    }

    private func performDownload(_ model: PromptModel) async throws {
        let fm = FileManager.default
        let staging = PromptModel.root.appending(path: ".staging-\(model.id)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files = try await HuggingFace.listFiles(repo: model.repo, prefix: "")
            .filter { !$0.path.hasPrefix(".") && $0.path != "README.md" }
        guard files.contains(where: { $0.path == "config.json" }) else { throw URLError(.fileDoesNotExist) }
        try await HuggingFace.download(repo: model.repo, files: files, into: staging) { fraction in
            self.downloads[model.id] = fraction
        }
        if model.source == .added {
            let info = PromptModel.AddedInfo(repo: model.repo, size: model.size)
            try JSONEncoder().encode(info).write(to: staging.appending(path: PromptModel.sourceFile))
        }
        let dest = PromptModel.root.appending(path: model.id, directoryHint: .isDirectory)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)
    }
}

/// Runs a prompt model in its own mlx_worker.py process. The model stays loaded for a few
/// minutes after the last request (enhancing again is common), then the process exits to
/// give its ~3 GB back to the image models.
final class MLXPromptRewriter: @unchecked Sendable {
    static let shared = MLXPromptRewriter()

    private let queue = DispatchQueue(label: "MLXPromptRewriter")
    private let worker = MLXWorker()
    private var loadedID: String? {
        didSet {
            guard loadedID != oldValue else { return }
            let id = loadedID
            Task { @MainActor in PromptMemory.shared.mlxModelID = id }
        }
    }
    private var idleUnload: DispatchWorkItem?
    /// Minutes unused before the language model is freed (Settings → Speed & Memory). Ollama
    /// is asked to keep its model for the same time.
    static let idleKey = "promptModelIdleMinutes"
    static var idleSeconds: Double { Double(max(UserDefaults.standard.integer(forKey: idleKey), 1)) * 60 }

    func chat(model: PromptModel, system: String, user: String, temperature: Double) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try self.run(model: model, system: system, user: user, temperature: temperature)
                })
            }
        }
    }

    func unload() {
        queue.async {
            self.idleUnload?.cancel()
            self.worker.terminate()
            self.loadedID = nil
        }
    }

    private func run(model: PromptModel, system: String, user: String, temperature: Double) throws -> String {
        idleUnload?.cancel()
        defer { scheduleIdleUnload() }
        guard MLXRuntime.isInstalled else {
            throw RuntimeError("Install the MLX runtime first (Models → MLX runtime).")
        }
        guard let folder = model.folder else {
            throw RuntimeError("Download \(model.name) in Settings first.")
        }
        do {
            if !worker.isRunning {
                loadedID = nil
                try worker.start()
            }
            if loadedID != model.id {
                try worker.send(["op": "load_lm", "path": folder.path])
                try waitFor("loaded")
                loadedID = model.id
            }
            try worker.send([
                "op": "chat",
                "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
                "temperature": temperature,
                "max_tokens": 300,
            ])
            return try waitFor("reply")["text"] as? String ?? ""
        } catch let stopped as MLXWorker.Stopped {
            loadedID = nil
            throw RuntimeError("The prompt model stopped\(stopped.status.map { " (status \($0))" } ?? ""). "
                               + "Log: \(MLXRuntime.logURL.path)")
        }
    }

    private func waitFor(_ name: String) throws -> [String: Any] {
        while true {
            let event = try worker.nextEvent()
            switch event["event"] as? String {
            case name:
                return event
            case "error":
                throw RuntimeError(event["message"] as? String ?? "The prompt model failed.")
            default:
                continue
            }
        }
    }

    private func scheduleIdleUnload() {
        let item = DispatchWorkItem { [weak self] in
            self?.worker.terminate()
            self?.loadedID = nil
        }
        idleUnload = item
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: item)
    }
}

/// Which Add Detail model is holding memory, so Create and Settings can offer to free it:
/// the MLX rewriter's model, and the Ollama model this app last used (kept for the idle time
/// the app asks Ollama for). Apple Intelligence's memory is managed by macOS.
@MainActor
@Observable
final class PromptMemory {
    static let shared = PromptMemory()

    /// Set by MLXPromptRewriter as its worker loads and frees models.
    fileprivate(set) var mlxModelID: String?
    private(set) var ollamaModel: String?
    private var ollamaExpiry: Task<Void, Never>?
    private(set) var isUnloading = false

    /// The loaded model as shown to the user, e.g. "Qwen3 4B Instruct (MLX)".
    var loadedName: String? {
        let names = [mlxModelID.map { "\(PromptModel.named($0).name) (MLX)" }, ollamaModel.map { "\($0) (Ollama)" }]
        let loaded = names.compactMap { $0 }
        return loaded.isEmpty ? nil : loaded.joined(separator: " and ")
    }

    /// Ollama answered with `model`, which it now keeps for `seconds`.
    func ollamaUsed(_ model: String, for seconds: Double) {
        ollamaModel = model
        ollamaExpiry?.cancel()
        ollamaExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.ollamaModel = nil
        }
    }

    /// Frees every loaded Add Detail model now.
    func unload() async {
        isUnloading = true
        defer { isUnloading = false }
        if mlxModelID != nil { MLXPromptRewriter.shared.unload() }  // it reports nil when done
        if let model = ollamaModel {
            ollamaExpiry?.cancel()
            try? await Ollama.unload(model: model)
            ollamaModel = nil
        }
    }
}
