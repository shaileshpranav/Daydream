import SwiftUI

/// Settings → Add Detail: which engine rewrites prompts, and its model.
struct PromptEnhancerSettings: View {
    @Environment(MLXRuntime.self) private var runtime
    @Environment(PromptModelStore.self) private var promptModels
    @AppStorage(PromptEnhancer.engineKey) private var engine = PromptEnhancer.Engine.appleIntelligence
    @AppStorage(PromptEnhancer.modelKey) private var mlxModelID = PromptModel.defaultID
    @AppStorage(Ollama.urlKey) private var ollamaURL = ""
    @AppStorage(Ollama.modelKey) private var ollamaModel = ""

    @State private var repoToAdd = ""
    @State private var adding = false
    @State private var addError: String?
    @State private var ollamaModels: [Ollama.ModelInfo] = []
    @State private var ollamaError: String?
    @State private var loadingOllama = false

    var body: some View {
        Section("Add Detail (prompt rewriting)") {
            Picker("Rewrite prompts with", selection: $engine) {
                ForEach(PromptEnhancer.Engine.allCases) { Text($0.label).tag($0) }
            }
            switch engine {
            case .appleIntelligence:
                caption("Uses Apple's on-device model. Needs macOS 26 with Apple Intelligence turned on.")
            case .mlx:
                mlxSettings
            case .ollama:
                ollamaSettings
            }
        }
    }

    // MARK: MLX

    @ViewBuilder
    private var mlxSettings: some View {
        let _ = promptModels.revision
        let models = PromptModel.all
        let selected = models.first { $0.id == mlxModelID } ?? models[0]
        Picker("Model", selection: $mlxModelID) {
            modelGroup("Recommended", models.filter { $0.source == .catalog })
            modelGroup("Added from Hugging Face", models.filter { $0.source == .added })
            modelGroup("Found on this Mac", models.filter { $0.source == .huggingFaceCache })
        }
        modelRow(selected)
        HStack {
            TextField("Add from Hugging Face", text: $repoToAdd, prompt: Text("mlx-community/Phi-4-mini-instruct-4bit"))
                .onSubmit(addRepo)
            if adding {
                ProgressView().controlSize(.small)
            } else {
                Button("Add", action: addRepo)
                    .disabled(repoToAdd.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if let error = addError ?? promptModels.lastError {
            Text(error).font(.caption).foregroundStyle(.red)
        }
        if runtime.status != .installed { runtimeRow }
        caption("Runs the model on the GPU with MLX. It loads when you press Add Detail and frees its memory after 3 minutes unused. Any mlx-lm chat model works: search Hugging Face for mlx-community and a 4-bit model under about 4 GB. MLX language models already in your Hugging Face cache are listed without downloading again.")
    }

    @ViewBuilder
    private func modelGroup(_ title: String, _ models: [PromptModel]) -> some View {
        if !models.isEmpty {
            Section(title) {
                ForEach(models) { model in
                    Text("\(model.name) (\(model.size))\(model.isInstalled ? "  ✓" : "")").tag(model.id)
                }
            }
        }
    }

    private func modelRow(_ model: PromptModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if !model.notes.isEmpty {
                    Text(model.notes).font(.caption).foregroundStyle(.secondary)
                }
                if let fraction = promptModels.downloads[model.id] {
                    ProgressView(value: fraction)
                }
            }
            Spacer()
            if promptModels.downloads[model.id] != nil {
                Button("Cancel") { promptModels.cancel(model) }
            } else if model.usesHuggingFaceCache {
                Label("In Hugging Face cache", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.isInstalled {
                Label("Downloaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Delete") { promptModels.delete(model) }
            } else {
                Button("Download \(model.size)") { promptModels.download(model) }
            }
        }
    }

    private var runtimeRow: some View {
        HStack {
            Text("Also needs the MLX runtime.").font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch runtime.status {
            case .installing(let line):
                Text(line).font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                Button("Retry") { runtime.install() }
            default:
                Button("Install") { runtime.install() }
            }
        }
    }

    private func addRepo() {
        let repo = repoToAdd
        guard !repo.trimmingCharacters(in: .whitespaces).isEmpty, !adding else { return }
        adding = true
        addError = nil
        Task {
            do {
                mlxModelID = try await promptModels.add(repo: repo)
                repoToAdd = ""
            } catch {
                addError = error.localizedDescription
            }
            adding = false
        }
    }

    // MARK: Ollama

    @ViewBuilder
    private var ollamaSettings: some View {
        TextField("Server", text: $ollamaURL, prompt: Text(Ollama.defaultURL))
            .onSubmit { Task { await refreshOllama() } }
        HStack {
            Picker("Model", selection: $ollamaModel) {
                if ollamaModel.isEmpty { Text("Choose…").tag("") }
                // Keep the saved choice listed while the server is unreachable.
                if !ollamaModel.isEmpty, !ollamaModels.contains(where: { $0.name == ollamaModel }) {
                    Text(ollamaModel).tag(ollamaModel)
                }
                ForEach(ollamaModels) { model in
                    Text("\(model.name) (\(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)))")
                        .tag(model.name)
                }
            }
            if loadingOllama {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await refreshOllama() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload the list of models from Ollama")
            }
        }
        if let ollamaError {
            HStack {
                Text(ollamaError).font(.caption).foregroundStyle(.red)
                Spacer()
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.ollama")
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.ollama.ollama") {
                    Button("Open Ollama") {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .seconds(3))
                                await refreshOllama()
                            }
                        }
                    }
                }
            }
        } else if !loadingOllama, ollamaModels.isEmpty {
            caption("Ollama has no models yet. Pull one in Terminal, e.g. ollama pull qwen3:4b")
        }
        caption("Uses a model from your Ollama server (ollama.com). Smaller models answer faster; 3–9B is plenty for rewriting prompts. Ollama keeps the model loaded for 5 minutes after each rewrite.")
            .task(id: ollamaURL) { await refreshOllama() }
    }

    private func refreshOllama() async {
        loadingOllama = true
        defer { loadingOllama = false }
        do {
            ollamaModels = try await Ollama.models()
            ollamaError = nil
            if ollamaModel.isEmpty, let first = ollamaModels.first { ollamaModel = first.name }
        } catch {
            ollamaModels = []
            ollamaError = error.localizedDescription
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
