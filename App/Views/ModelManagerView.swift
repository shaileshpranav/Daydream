import SwiftUI
import UniformTypeIdentifiers

/// Models, LoRAs and installing new ones: a list on the left, details on the right.
struct ModelManagerView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case models = "My Models"
        case loras = "Style Add-ons"
        case add = "Get Models"
        var id: String { rawValue }
    }

    @Environment(ModelStore.self) private var store
    @Environment(LoRALibrary.self) private var loras
    @State private var tab: Tab = .models
    @State private var selectedModelID: String?
    @State private var selectedLoRA: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tabTitle(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            .padding(10)
            Divider()
            if let error = store.lastError ?? loras.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            switch tab {
            case .models: modelsTab
            case .loras: lorasTab
            case .add: AddModelsView()
            }
        }
        .navigationTitle("Models")
        .toolbar {
            Button("Reveal Models Folder", systemImage: "folder") { NSWorkspace.shared.open(store.root) }
        }
        .onAppear {
            if store.installed.isEmpty { tab = .add }
            if selectedModelID == nil { selectedModelID = store.installed.first?.id }
            loras.reload()
        }
    }

    private func tabTitle(_ tab: Tab) -> String {
        switch tab {
        case .models: "My Models (\(store.installed.count))"
        case .loras: "Style Add-ons (\(loras.items.count))"
        case .add: store.downloads.isEmpty ? "Get Models" : "Get Models (\(store.downloads.count)↓)"
        }
    }

    // MARK: Models

    private var modelsTab: some View {
        HSplitView {
            List(selection: $selectedModelID) {
                Section {
                    ForEach(store.installed) { model in
                        ModelListRow(model: model).tag(model.id)
                    }
                } header: {
                    StorageSummary()
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .overlay {
                if store.installed.isEmpty {
                    ContentUnavailableView {
                        Label("No models yet", systemImage: "shippingbox")
                    } description: {
                        Text("A model is what makes the pictures. Download one to get started.")
                    } actions: {
                        Button("Get Models") { tab = .add }.buttonStyle(.borderedProminent)
                    }
                }
            }
            Group {
                if let model = store.model(id: selectedModelID) {
                    ModelDetailView(model: model)
                        .id(model.id)
                } else {
                    ContentUnavailableView("Select a model", systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: LoRAs

    private var lorasTab: some View {
        HSplitView {
            List(selection: $selectedLoRA) {
                ForEach(loras.items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).lineLimit(1).truncationMode(.middle)
                        Text("\(item.base?.label ?? "Unknown base") · \(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))")
                            .font(.caption)
                            .foregroundStyle(item.base == nil ? .orange : .secondary)
                    }
                    .tag(item.id)
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            .overlay {
                if loras.items.isEmpty {
                    ContentUnavailableView("No style add-ons", systemImage: "square.stack.3d.up",
                                           description: Text("Style add-ons (LoRAs) teach a model a particular look or character. They're optional. Import .safetensors files or download one below."))
                }
            }
            .safeAreaInset(edge: .bottom) { LoRAAddBar() }
            Group {
                if let item = loras.item(path: selectedLoRA) {
                    LoRADetailView(item: item).id(item.id)
                } else {
                    ContentUnavailableView("Select a LoRA", systemImage: "sidebar.left")
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

// MARK: - Model list and detail

private struct StorageSummary: View {
    @Environment(ModelStore.self) private var store
    @State private var used: Int64?

    var body: some View {
        HStack {
            Text("\(store.installed.count) installed")
            Spacer()
            if let used { Text(ByteCountFormatter.string(fromByteCount: used, countStyle: .file) + " used") }
            if let free = store.freeDiskBytes {
                Text("· " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free")
            }
        }
        .font(.caption)
        .task(id: store.installed.map(\.id)) {
            let root = store.root
            used = await Task.detached { ModelStore.directorySize(root) }.value
        }
    }
}

private struct ModelListRow: View {
    @Environment(Generator.self) private var generator
    let model: InstalledModel

    var body: some View {
        HStack {
            Image(systemName: model.kind == .mlx ? "cpu" : "brain")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name).lineLimit(1)
                Text(ModelBlurb.tagline(for: model)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(model.backendLabel)
            }
            Spacer()
            if generator.loadedModelID == model.id {
                Text("ready")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .background(.green.opacity(0.2), in: Capsule())
            }
        }
    }
}

private struct ModelDetailView: View {
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @Environment(AppState.self) private var app
    @Environment(GenerationQueue.self) private var queue
    let model: InstalledModel
    @State private var draft: InstalledModel
    @State private var diskBytes: Int64?
    @State private var confirmTrash = false

    init(model: InstalledModel) {
        self.model = model
        _draft = State(initialValue: model)
    }

    private var defaults: ModelDefaults { draft.defaults ?? draft.recommended }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .font(.title3)
                    .onSubmit(save)
                Text(ModelBlurb.tagline(for: model)).foregroundStyle(.secondary)
                LabeledContent("Backend", value: model.backendLabel)
                if let source = model.source ?? model.catalogEntry?.repo {
                    LabeledContent("Source") {
                        Link(source, destination: URL(string: "https://huggingface.co/\(source)")!)
                    }
                }
                LabeledContent("Location") {
                    Button(model.folder.lastPathComponent) {
                        NSWorkspace.shared.activateFileViewerSelecting([model.folder])
                    }
                    .buttonStyle(.link)
                }
                if let notes = model.catalogEntry?.notes { Text(notes).font(.callout).foregroundStyle(.secondary) }
                if let license = model.catalogEntry?.license { Text(license).font(.callout).foregroundStyle(.orange) }
            }

            Section("Memory") {
                if let diskBytes {
                    let weights = Double(diskBytes) / 1e9
                    let estimate = MemoryEstimate.gigabytes(weightsGB: weights, kind: model.kind, resolution: draft.resolution)
                    let fit = MemoryEstimate.fit(estimate)
                    LabeledContent("On disk", value: ByteCountFormatter.string(fromByteCount: diskBytes, countStyle: .file))
                    VStack(alignment: .leading, spacing: 4) {
                        Gauge(value: min(estimate, MemoryEstimate.ramGB), in: 0...MemoryEstimate.ramGB) {
                            Text("While generating: about \(estimate, specifier: "%.1f") GB of \(Int(MemoryEstimate.ramGB.rounded())) GB")
                        }
                        .tint(fit == .comfortable ? .green : fit == .tight ? .orange : .red)
                        Text(fit.label + (model.kind == .mlx ? " (at \(draft.resolution)×\(draft.resolution); smaller sizes use less)" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section {
                Stepper("Steps: \(defaults.steps)", value: Binding(
                    get: { defaults.steps },
                    set: { setDefaults(steps: $0) }
                ), in: 1...100)
                VStack(alignment: .leading) {
                    Text("Guidance: \(defaults.guidance, specifier: "%.1f")")
                    Slider(value: Binding(get: { defaults.guidance }, set: { setDefaults(guidance: $0) }),
                           in: 0...20, step: 0.5)
                }
                if model.kind == .mlx {
                    Picker("Base size", selection: $draft.resolution) {
                        ForEach([512, 640, 768, 1024, 1280], id: \.self) { Text("\($0) px").tag($0) }
                    }
                    .onChange(of: draft.resolution) { save() }
                } else {
                    LabeledContent("Size", value: "\(model.resolution) × \(model.resolution) (fixed at conversion)")
                    Picker("Compute units", selection: $draft.computeUnits) {
                        ForEach(ComputeUnitsChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: draft.computeUnits) { save() }
                    .disabled(generator.isBusy)
                }
                if let builtIn = model.builtInDefaults, builtIn != draft.defaults {
                    Button("Reset to Built-in (\(builtIn.steps) steps, guidance \(builtIn.guidance, specifier: "%.1f"))") {
                        draft.defaults = builtIn
                        save()
                    }
                }
            } header: {
                Text("Defaults")
            } footer: {
                Text("Used when you pick this model in Create, and for its Standard quality.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let fused = model.loras, !fused.isEmpty {
                Section("Fused LoRAs") {
                    ForEach(fused, id: \.self) { Text($0.label) }
                }
            }
            if let base = model.loraBase {
                Section("LoRAs") {
                    LabeledContent("Accepts", value: "\(base.label) LoRAs, added in Create › Advanced")
                }
            }

            Section {
                HStack {
                    Button("Create with This Model") {
                        app.selectedModelID = model.id
                        app.section = .generate
                    }
                    if generator.loadedModelID == model.id {
                        Button("Unload") { generator.unloadModel() }
                            .disabled(generator.isBusy || queue.isRunning)
                    } else {
                        Button("Load Now") {
                            Task { await generator.preload(model: model, request: app.request) }
                        }
                        .disabled(generator.isBusy || queue.isRunning)
                    }
                    if case .loading(let name) = generator.phase, name == model.name {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                        .disabled(generator.isBusy || queue.isRunning)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { if draft.name != model.name { save() } }
        .task(id: model.id) {
            let folder = model.folder!
            diskBytes = await Task.detached { ModelStore.directorySize(folder) }.value
        }
        .confirmationDialog("Move \(model.name) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                if generator.loadedModelID == model.id { generator.unloadModel() }
                store.moveToTrash(model)
            }
        } message: {
            Text("This frees \(diskBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "its disk space") once the Trash is emptied. You can restore it from the Trash until then.")
        }
    }

    private func setDefaults(steps: Int? = nil, guidance: Double? = nil) {
        let current = defaults
        draft.defaults = ModelDefaults(steps: steps ?? current.steps, guidance: guidance ?? current.guidance,
                                       supportsNegativePrompt: current.supportsNegativePrompt)
        save()
    }

    private func save() {
        var updated = draft
        updated.name = updated.name.trimmingCharacters(in: .whitespaces)
        if updated.name.isEmpty { updated.name = model.name }
        guard updated != model else { return }
        store.update(updated)
    }
}

// MARK: - LoRA detail

private struct LoRAAddBar: View {
    @Environment(LoRALibrary.self) private var loras
    @State private var importing = false
    @State private var repo = ""
    @State private var progress: Double?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Hugging Face repo", text: $repo, prompt: Text("user/lora-repo"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(download)
                if let progress {
                    ProgressView(value: progress).frame(width: 60)
                } else {
                    Button("Download", action: download).disabled(!repo.contains("/"))
                }
            }
            HStack {
                Button("Import Files…") { importing = true }
                Button("Rescan") { loras.reload() }
                Spacer()
                Button("Open Folder") { NSWorkspace.shared.open(ModelStore.lorasFolder) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }
        .controlSize(.small)
        .padding(8)
        .background(.bar)
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { loras.importFiles(urls) }
        }
    }

    private func download() {
        guard repo.contains("/"), progress == nil else { return }
        progress = 0
        error = nil
        Task {
            do {
                _ = try await loras.download(repo: repo) { progress = $0 }
                repo = ""
            } catch {
                self.error = error.localizedDescription
            }
            progress = nil
        }
    }
}

private struct LoRADetailView: View {
    @Environment(LoRALibrary.self) private var loras
    @Environment(ModelStore.self) private var store
    let item: LoRALibrary.Item
    @State private var settings = LoRALibrary.Settings()
    @State private var confirmTrash = false

    var body: some View {
        Form {
            Section {
                Text(item.name).font(.title3)
                LabeledContent("Made for") {
                    switch item.result {
                    case .known(let base): Text(base.label)
                    case .unknown(let reason): Text(reason).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
                if let steps = item.trainingSteps { LabeledContent("Trained for", value: "\(steps) steps") }
                LabeledContent("Location") {
                    Button(item.url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        .buttonStyle(.link)
                }
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Default strength: \(settings.defaultScale, specifier: "%.2f")")
                    Slider(value: $settings.defaultScale, in: 0...1.5, step: 0.05)
                }
                TextField("Trigger words", text: $settings.triggerWords, prompt: Text("words the LoRA was trained on"))
                if !item.suggestedTriggers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From its training data:").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            ForEach(item.suggestedTriggers, id: \.self) { tag in
                                Button(tag) { addTrigger(tag) }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("When added in Create")
            } footer: {
                Text("New uses start at this strength, and Create offers to insert the trigger words into your description.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let base = item.base {
                Section("Works with") {
                    let compatible = store.installed.filter { $0.loraBase == base }
                    if compatible.isEmpty {
                        Text("No installed \(base.label) model. Install one from Get Models.").foregroundStyle(.secondary)
                    }
                    ForEach(compatible) { Text($0.name) }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { settings = loras.settings(for: item.url) }
        .onChange(of: settings) { loras.update(settings, for: item.url) }
        .confirmationDialog("Move \(item.name) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { loras.moveToTrash(item) }
        }
    }

    private func addTrigger(_ tag: String) {
        let words = settings.triggerWords.trimmingCharacters(in: .whitespaces)
        guard !words.localizedCaseInsensitiveContains(tag) else { return }
        settings.triggerWords = words.isEmpty ? tag : "\(words), \(tag)"
    }
}

// MARK: - Add models

private struct AddModelsView: View {
    @Environment(ModelStore.self) private var store
    @State private var importing = false
    @State private var pendingImport: URL?
    @AppStorage("showAdvancedInstall") private var showAdvanced = false

    private var available: [CatalogEntry] {
        ModelCatalog.entries.filter { !store.isInstalled($0) && store.downloads[$0.id] == nil }
    }

    var body: some View {
        List {
            if !store.downloads.isEmpty {
                Section("Downloading") {
                    ForEach(store.downloads.values.map(\.entry)) { entry in
                        CatalogRow(entry: entry)
                    }
                }
            }

            Section {
                ForEach(available) { entry in
                    CatalogRow(entry: entry)
                }
                if available.isEmpty {
                    Text("You've installed every model in the list.").foregroundStyle(.secondary)
                }
            } header: {
                Text("Available models")
            } footer: {
                Text("Downloads are large, and happen once. Each model works offline afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show advanced install options", isOn: $showAdvanced.animation())
            }

            if showAdvanced {
                Section {
                    HuggingFaceInstallRow()
                } header: {
                    Text("From Hugging Face (MLX)")
                } footer: {
                    Text("Any mflux-format repo of a supported family, e.g. from huggingface.co/mflux-community. Prefer -q4 versions on a 16 GB Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button("Import Converted Core ML Model…") { importing = true }
                } header: {
                    Text("Your own Core ML conversion")
                } footer: {
                    Text("A folder made by tools/convert/convert_sd.sh (see the README).").font(.caption).foregroundStyle(.secondary)
                }

                Section("MLX runtime") {
                    MLXRuntimeRow()
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { pendingImport = url }
        }
        .sheet(item: $pendingImport) { url in
            ImportSheet(source: url)
        }
    }
}

private struct HuggingFaceInstallRow: View {
    @Environment(ModelStore.self) private var store
    @Environment(MLXRuntime.self) private var runtime
    @State private var repo = ""
    @State private var family: MLXFamily?
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Repo", text: $repo, prompt: Text("mflux-community/flux2-klein-9b-mflux-q4"))
                    .onSubmit(install)
                    .onChange(of: repo) { family = MLXFamilies.detect(repo: repo) }
                Picker("Family", selection: $family) {
                    Text("Choose family…").tag(MLXFamily?.none)
                    ForEach(MLXFamilies.all) { Text($0.label).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 200)
                if checking {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Install", action: install)
                        .disabled(!repo.contains("/") || family == nil)
                }
            }
            if let family {
                Text("\(family.label): \(family.defaults.steps) steps, guidance \(family.defaults.guidance, specifier: "%.1f"), \(family.resolution) px")
                    .font(.caption).foregroundStyle(.secondary)
            } else if repo.contains("/") {
                Text("Couldn't tell the model family from the name. Pick it, or check the repo is a supported model.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if runtime.status != .installed {
                Text("MLX models also need the MLX runtime (below).").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func install() {
        guard let family, repo.contains("/"), !checking else { return }
        checking = true
        error = nil
        Task {
            do {
                try await store.installFromHuggingFace(repo: repo, family: family)
                repo = ""
            } catch {
                self.error = error.localizedDescription
            }
            checking = false
        }
    }
}

private struct CatalogRow: View {
    @Environment(ModelStore.self) private var store
    @Environment(MLXRuntime.self) private var runtime
    let entry: CatalogEntry

    var body: some View {
        let estimate = MemoryEstimate.gigabytes(weightsGB: entry.approxGB, kind: entry.kind, resolution: entry.resolution)
        let fit = MemoryEstimate.fit(estimate)
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.name).font(.headline)
                    if entry.id == ModelBlurb.starterID {
                        Text("Best to start with")
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.2), in: Capsule())
                    }
                }
                Text(ModelBlurb.tagline(id: entry.id, kind: entry.kind, notes: entry.notes)).font(.callout)
                Text(["\(entry.approxGB.formatted(.number.precision(.fractionLength(1)))) GB download",
                      ModelBlurb.speed(id: entry.id).map { $0.prefix(1).uppercased() + $0.dropFirst() },
                      entry.kind == .mlx ? "Needs a one-time extra setup" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("\(entry.kind == .mlx ? "MLX" : "Core ML") · \(entry.resolution) px · \(entry.repo)")
                if let license = entry.license {
                    Text(license).font(.caption).foregroundStyle(.orange)
                }
                Label("Memory: \(fit.label.lowercased()) (about \(estimate, specifier: "%.0f") GB)", systemImage: "memorychip")
                    .font(.caption)
                    .foregroundStyle(fit == .comfortable ? Color.secondary : fit == .tight ? .orange : .red)
            }
            Spacer()
            if let download = store.downloads[entry.id] {
                ProgressView(value: download.fraction).frame(width: 140)
                Text("\(Int(download.fraction * 100))%").monospacedDigit().frame(width: 40)
                Button("Cancel") { store.cancelDownload(entry) }
            } else {
                Button("Download") {
                    store.download(entry)
                    // MLX models also need the Python runtime; set it up alongside.
                    if entry.kind == .mlx, runtime.status == .notInstalled { runtime.install() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ImportSheet: View {
    @Environment(ModelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: URL
    @State private var name = ""
    @State private var kind: ModelKind = .sd
    @State private var resolution = 512
    @State private var loras: [FusedLoRA] = []

    var body: some View {
        Form {
            Text("Import compiled Core ML resources from\n\(source.path)")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Name", text: $name)
            Picker("Kind", selection: $kind) {
                Text(ModelKind.sd.label).tag(ModelKind.sd)
                Text(ModelKind.sdxl.label).tag(ModelKind.sdxl)
            }
            Picker("Resolution", selection: $resolution) {
                ForEach([512, 768, 1024], id: \.self) { Text("\($0) px").tag($0) }
            }
            if !loras.isEmpty {
                LabeledContent("Fused LoRAs", value: loras.map(\.label).joined(separator: ", "))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Import") {
                    store.importFolder(source, name: name, kind: kind, resolution: resolution, loras: loras)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear(perform: prefill)
        .onChange(of: kind) { resolution = kind == .sdxl ? 1024 : 512 }
    }

    /// Uses model.json written by tools/convert/convert_sd.sh when present.
    private func prefill() {
        name = source.lastPathComponent
        struct Hint: Decodable { let name: String?; let kind: ModelKind?; let resolution: Int?; let loras: [FusedLoRA]? }
        let candidates = [source, ModelStore.findResourceDir(in: source)].compactMap { $0 }
        for dir in candidates {
            if let data = try? Data(contentsOf: dir.appending(path: "model.json")),
               let hint = try? JSONDecoder().decode(Hint.self, from: data) {
                name = hint.name ?? name
                kind = hint.kind ?? kind
                resolution = hint.resolution ?? (kind == .sdxl ? 1024 : 512)
                loras = hint.loras ?? []
                return
            }
        }
    }
}

/// Installs the Python + mflux environment that MLX models run in.
private struct MLXRuntimeRow: View {
    @Environment(MLXRuntime.self) private var runtime

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Python + \(MLXRuntime.package)").font(.headline)
                Text("Runs the MLX models (Z-Image, FLUX.2, Qwen-Image) on the GPU. Needs Python 3.11+ from Homebrew.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                switch runtime.status {
                case .installing(let line):
                    Text(line).font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                default:
                    EmptyView()
                }
            }
            Spacer()
            switch runtime.status {
            case .installed:
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Log") { NSWorkspace.shared.open(MLXRuntime.logURL) }
                    .disabled(!FileManager.default.fileExists(atPath: MLXRuntime.logURL.path))
            case .installing:
                ProgressView().controlSize(.small)
            case .notInstalled:
                Button("Install") { runtime.install() }
            case .failed:
                Button("Retry") { runtime.install() }
            }
        }
        .padding(.vertical, 4)
    }
}
