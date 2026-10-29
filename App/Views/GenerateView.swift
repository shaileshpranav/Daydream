import SwiftUI
import UniformTypeIdentifiers

/// The Create workspace: settings on the left, the image in the middle, recent pictures on the right.
struct GenerateView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @Environment(GenerationQueue.self) private var queue
    @Environment(LoRALibrary.self) private var library
    @Environment(Upscaler.self) private var upscaler
    @State private var fastModeError: String?
    @AppStorage(GenerationQueue.previewEveryKey) private var previewEvery = 5
    @AppStorage(GenerationQueue.lastPreviewEveryKey) private var lastPreviewEvery = 5
    @AppStorage("batchCount") private var batchCount = 1
    @AppStorage("randomSeed") private var randomSeed = true
    @AppStorage("preloadModels") private var preloadModels = true
    @AppStorage("showGalleryPanel") private var showGallery = true
    @AppStorage("showImageInfo") private var showInfo = false
    @AppStorage("accordion.generation") private var generationOpen = true
    @AppStorage("accordion.image") private var imageOpen = true
    @State private var viewedImage: CGImage?
    @State private var enhancing = false
    @State private var beforeEnhance: PromptEnhancer.Result?
    @State private var enhanceError: String?
    @State private var lastEnhanced: String?
    // Read so the Add Detail button updates when the engine changes in Settings.
    @AppStorage(PromptEnhancer.engineKey) private var enhancerEngine = PromptEnhancer.Engine.appleIntelligence.rawValue
    @AppStorage(PromptEnhancer.modelKey) private var enhancerModel = PromptModel.defaultID
    @AppStorage(Ollama.modelKey) private var ollamaModel = ""
    /// Saved pictures, newest first, for the gallery panel.
    @State private var records: [GenerationRecord] = []
    /// Pictures moved to the Trash this session, so the latest one disappears from view too.
    @State private var trashed: Set<String> = []
    @State private var confirmTrash = false
    @State private var trashError: String?
    @State private var zoom = ZoomState()

    private var runnableModels: [InstalledModel] {
        store.installed.filter { $0.kind.isRunnable }
    }

    private var selectedModel: InstalledModel? {
        store.model(id: app.selectedModelID) ?? runnableModels.first
    }

    var body: some View {
        Group {
            if runnableModels.isEmpty {
                WelcomeView()
            } else {
                HSplitView {
                    parameters
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)
                    viewer
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    if showGallery {
                        GalleryPanel(records: records, selected: shownRecord, onSelect: select, onTrash: trash)
                            .frame(minWidth: 180, idealWidth: 240, maxWidth: 420, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Create")
        .task {
            records = await ImageSaver.loadRecords()
            // Nothing made yet this session: show the newest saved picture instead of an empty canvas.
            if generator.lastRecord == nil, app.viewedRecord == nil { app.viewedRecord = records.first }
        }
        .onChange(of: generator.lastRecord) {
            app.viewedRecord = nil
            if let record = generator.lastRecord, !records.contains(record) {
                records.insert(record, at: 0)
            }
        }
        .onChange(of: upscaler.lastRecord) {
            guard let record = upscaler.lastRecord, !records.contains(record) else { return }
            records.insert(record, at: 0)
            // Upscaled from the picture on screen: show the result in its place.
            if record.upscale?.source == shownRecord?.fileName { app.viewedRecord = record }
        }
    }

    // MARK: Parameters panel

    private var parameters: some View {
        @Bindable var app = app
        return VStack(spacing: 0) {
            createHeader
            Divider()
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        if app.request.prompt.isEmpty {
                            Text("A cozy cabin in snowy woods at dusk, warm light in the windows…")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $app.request.prompt)
                            .font(.body)
                            .frame(minHeight: 96)
                            .scrollContentBackground(.hidden)
                    }
                    if selectedModel?.defaults?.supportsNegativePrompt ?? true {
                        TextField("Things to avoid", text: $app.request.negativePrompt,
                                  prompt: Text("Things to avoid: blurry, extra fingers, text"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(1...4)
                    }
                    promptTools
                    StyleChips(prompt: $app.request.prompt)
                } header: {
                    Text("Prompt").font(.headline)
                }

                generationSection
                imageSection
                StartImageSection(model: selectedModel)
                if let error = app.startImageError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if let selectedModel, selectedModel.kind == .mlx, selectedModel.loraBase != nil {
                    MLXLoRASection(model: selectedModel, loras: Binding(
                        get: { app.request.loras ?? [] },
                        set: { app.request.loras = $0 }
                    ))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.panel, ignoresSafeAreaEdges: [])
        .onChange(of: selectedModel?.id) { oldID, _ in
            applyDefaults(previous: store.model(id: oldID))
        }
        .task(id: selectedModel?.id) {
            await preloadSelectedModel()
        }
        .onAppear {
            guard !app.appliedLaunchDefaults, !app.automationRunning, let model = selectedModel else { return }
            app.appliedLaunchDefaults = true
            applyRecommended(for: model)
        }
    }

    private var canCreate: Bool {
        selectedModel != nil && !app.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The Create button, how many pictures to make, and stop: always visible at the top.
    private var createHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    guard let model = selectedModel else { return }
                    // The seed field shows the seed actually used, so it can be kept or reused.
                    if randomSeed { app.request.randomizeSeed() }
                    queue.enqueue(model: model, request: app.request, count: batchCount)
                } label: {
                    Label(createTitle, systemImage: queue.isRunning ? "text.badge.plus" : "wand.and.stars")
                }
                .buttonStyle(CreateButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCreate)
                .help(canCreate ? "⌘↩" : "Write a prompt first")

                HStack(spacing: 2) {
                    Text("×\(batchCount)")
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                    Stepper("Pictures", value: $batchCount, in: 1...50)
                        .labelsHidden()
                }
                .help(batchCount == 1 || randomSeed ? "How many pictures to make"
                      : "How many pictures to make: variations \(app.request.seed)–\(app.request.seed &+ UInt32(batchCount - 1))")

                Button("Stop", systemImage: "xmark") { queue.cancelCurrent() }
                    .buttonStyle(IconButtonStyle(size: 34))
                    .keyboardShortcut(.cancelAction)
                    .disabled(!queue.isRunning)
                    .help("Stop the picture being made (Esc); the rest still get made")
            }
            if queue.isRunning {
                HStack(spacing: 4) {
                    Text(queue.pendingCount == 0 ? "Making 1 picture" : "Making 1 · \(queue.pendingCount) waiting")
                    if queue.pendingCount > 0 {
                        Text("·")
                        Button("Stop All") { queue.cancelAll() }
                            .buttonStyle(.link)
                        Text("·")
                        Button("View Queue") { app.section = .queue }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var createTitle: String {
        if queue.isRunning { return "Add to Queue" }
        return batchCount == 1 ? "Create" : "Create \(batchCount)"
    }

    private var promptTools: some View {
        _ = (enhancerEngine, enhancerModel, ollamaModel)
        let availability = PromptEnhancer.availability
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    app.request.prompt = SurprisePrompts.next(after: app.request.prompt)
                } label: {
                    Label("Surprise Me", systemImage: "dice")
                }
                .help("Fill in an example prompt")

                Button {
                    enhance()
                } label: {
                    Label("Add Detail", systemImage: "sparkles")
                }
                .disabled(enhancing || generator.isBusy || availability != .available
                          || app.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(availabilityHelp(availability))
                .keyboardShortcut("e", modifiers: .command)

                if enhancing {
                    ProgressView().controlSize(.small)
                } else if beforeEnhance != nil {
                    Button("Undo") {
                        if let before = beforeEnhance {
                            app.request.prompt = before.prompt
                            app.request.negativePrompt = before.negativePrompt
                        }
                        beforeEnhance = nil
                    }
                }

                if let loaded = PromptMemory.shared.loadedName {
                    Spacer()
                    Button("Unload Add Detail Model", systemImage: "eject") {
                        Task { await PromptMemory.shared.unload() }
                    }
                    .labelStyle(.iconOnly)
                    .disabled(enhancing || PromptMemory.shared.isUnloading)
                    .help("\(loaded) is in memory. Click to free it now")
                }
            }
            .controlSize(.small)
            if let enhanceError {
                Text(enhanceError).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: app.request.prompt) {
            // A manual edit becomes the new starting point for the next enhance.
            if app.request.prompt != lastEnhanced { beforeEnhance = nil }
        }
    }

    // MARK: Accordions

    private var generationSection: some View {
        @Bindable var app = app
        return Section {
            if generationOpen {
                Picker("Model", selection: Binding(
                    get: { selectedModel?.id },
                    set: { app.selectedModelID = $0 }
                )) {
                    ForEach(runnableModels) { model in
                        Text(model.name).tag(Optional(model.id))
                    }
                }
                if let selectedModel {
                    Text(ModelBlurb.tagline(for: selectedModel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let loras = selectedModel.loras, !loras.isEmpty {
                        LabeledContent("Built-in style", value: loras.map(\.label).joined(separator: ", "))
                            .help("Fused into this model at conversion. Add the LoRA's trigger words to your prompt.")
                    }
                    if let fast = selectedModel.fastLoRA {
                        fastModeRow(for: selectedModel, fast: fast)
                    }
                    qualityRow(for: selectedModel)
                }
                Stepper("Steps: \(app.request.steps)", value: $app.request.steps, in: 1...100)
                VStack(alignment: .leading) {
                    Text("Guidance: \(app.request.guidance, specifier: "%.1f")")
                    Slider(value: $app.request.guidance, in: 0...20, step: 0.5)
                }
                .help("How closely to follow the prompt. Higher follows the words more literally; too high looks harsh.")
                if let selectedModel {
                    if selectedModel.kind == .mlx {
                        let float16 = MLXFamilies.family(id: selectedModel.mlxFamily)?.float16Compute ?? true
                        LabeledContent("Runs on", value: float16 ? "GPU (MLX, float16)" : "GPU (MLX)")
                    } else {
                        Picker("Scheduler", selection: $app.request.scheduler) {
                            ForEach(SchedulerChoice.allCases) { Text($0.rawValue).tag($0) }
                        }
                        LabeledContent("Runs on", value: selectedModel.computeUnits.label)
                    }
                    recommendedRow(for: selectedModel)
                }
            }
        } header: {
            AccordionHeader(title: "Generation",
                            summary: [selectedModel?.name, "\(app.request.steps) steps"].compactMap { $0 }.joined(separator: " · "),
                            isExpanded: $generationOpen)
        }
    }

    private var imageSection: some View {
        @Bindable var app = app
        return Section {
            if imageOpen {
                shapeRow
                HStack {
                    TextField("Seed", value: $app.request.seed, format: .number.grouping(.never))
                        .disabled(randomSeed)
                    Button {
                        app.request.randomizeSeed()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("Pick a random seed")
                    .disabled(randomSeed)
                }
                .help("The same prompt, settings and seed give the same picture.")
                Toggle("New random seed each time", isOn: $randomSeed)
                    .help("Off: keep the seed to tweak one picture by changing only the prompt or settings")
            }
        } header: {
            AccordionHeader(title: "Image", summary: imageSummary, isExpanded: $imageOpen)
        }
    }

    private var imageSummary: String? {
        guard let model = selectedModel else { return nil }
        if model.kind.hasFixedSize { return "\(model.resolution)×\(model.resolution)" }
        let aspect = app.request.aspect ?? .square
        let size = aspect.size(base: model.resolution)
        return "\(aspect.rawValue) · \(size.width)×\(size.height)"
    }

    @ViewBuilder
    private var shapeRow: some View {
        if let selectedModel {
            if selectedModel.kind.hasFixedSize {
                LabeledContent("Shape", value: "Square, \(selectedModel.resolution) × \(selectedModel.resolution)")
                    .help("\(selectedModel.name) only makes square pictures")
            } else {
                let size = (app.request.aspect ?? .square).size(base: selectedModel.resolution)
                Picker("Shape", selection: Binding(
                    get: { app.request.aspect ?? .square },
                    set: { app.request.aspect = $0 }
                )) {
                    ForEach(AspectChoice.allCases) { Text($0.friendlyName).tag($0) }
                }
                .help("\(size.width) × \(size.height) pixels")
            }
        }
    }

    // MARK: Fast mode

    /// Fast mode is on when the model's few-step LoRA is in the request, so a saved
    /// picture or queued job carries it like any other LoRA.
    private func isFast(_ model: InstalledModel) -> Bool {
        guard let fast = model.fastLoRA else { return false }
        return app.request.loras?.contains { $0.source == fast.localURL.path } ?? false
    }

    private func fastModeRow(for model: InstalledModel, fast: FastLoRA) -> some View {
        let progress = library.downloads[fast.repo]
        let on = isFast(model)
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("Fast mode", isOn: Binding(get: { on }, set: { setFast($0, model: model, fast: fast) }))
                .disabled(progress != nil)
            if let progress {
                ProgressView(value: progress) {
                    Text("Downloading the fast-mode add-on (\(fast.approxGB.formatted()) GB, once)…").font(.caption)
                }
            } else {
                Text(on
                     ? "\(fast.steps) steps, one model run each, with the \(LoRARef(source: fast.localURL.path).name) LoRA. Uses about \(fast.approxGB.formatted()) GB more memory."
                     : "Off: \(model.recommended.steps) steps with two model runs each, which is slow on this Mac. On: \(fast.steps) runs in all."
                       + (fast.isDownloaded ? "" : " Turning it on downloads a \(fast.approxGB.formatted()) GB add-on once."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let fastModeError {
                Text(fastModeError).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func setFast(_ on: Bool, model: InstalledModel, fast: FastLoRA) {
        fastModeError = nil
        let path = fast.localURL.path
        guard on else {
            app.request.loras?.removeAll { $0.source == path }
            applyRecommended(for: model)
            return
        }
        guard fast.isDownloaded else {
            Task {
                do {
                    _ = try await library.download(repo: fast.repo) { _ in }
                    guard fast.isDownloaded else {
                        fastModeError = "The download didn't contain \(fast.file)."
                        return
                    }
                    // Only switch on if this model is still selected.
                    if selectedModel?.id == model.id { setFast(true, model: model, fast: fast) }
                } catch {
                    fastModeError = "Couldn't download the fast-mode add-on: \(error.localizedDescription)"
                }
            }
            return
        }
        var loras = app.request.loras ?? []
        if !loras.contains(where: { $0.source == path }) {
            loras.append(LoRARef(source: path, scale: 1, base: model.loraBase))
        }
        app.request.loras = loras
        applyRecommended(for: model)
    }

    /// Steps and guidance to recommend: the few-step LoRA's in Fast mode.
    private func recommended(for model: InstalledModel) -> ModelDefaults {
        if isFast(model), let fast = model.fastLoRA { return fast.defaults }
        return model.recommended
    }

    private func qualityRow(for model: InstalledModel) -> some View {
        let recommended = recommended(for: model)
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Quality", selection: Binding<Quality?>(
                get: { Quality.allCases.first { $0.steps(for: recommended) == app.request.steps } },
                set: { if let quality = $0 { app.request.steps = quality.steps(for: recommended) } }
            )) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            Text(Quality.allCases.contains { $0.steps(for: recommended) == app.request.steps }
                 ? "More steps take longer and add detail."
                 : "Custom number of steps")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func recommendedRow(for model: InstalledModel) -> some View {
        let r = recommended(for: model)
        let summary = "\(r.steps) steps · guidance \(r.guidance.formatted(.number.precision(.fractionLength(1))))"
            + (model.kind == .mlx ? "" : " · DPM-Solver++")
        return HStack {
            Text("Recommended: \(summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isRecommended(for: model) {
                Label("In use", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Reset") { applyRecommended(for: model) }
                    .help("Set steps, guidance\(model.kind == .mlx ? "" : " and scheduler") to what \(model.name) is tuned for")
            }
        }
    }

    // MARK: Model defaults

    /// Loads the selected model shortly after it's picked (or at launch), so Create starts at
    /// once instead of waiting 5–10 s (MLX) or minutes (a Core ML model's first compile).
    /// Coming back to Create doesn't load it again: if it was freed (Unload, or the idle
    /// timer in Settings), it stays freed until a picture needs it.
    private func preloadSelectedModel() async {
        guard preloadModels, !app.automationRunning, let model = selectedModel,
              app.preloadedModelID != model.id else { return }
        try? await Task.sleep(for: .seconds(1.5))  // don't load every model clicked past
        guard !Task.isCancelled else { return }
        // Handled once per pick, even when it's already loaded or the queue is busy.
        app.preloadedModelID = model.id
        guard !queue.isRunning, !generator.isBusy, generator.loadedModelID != model.id else { return }
        await generator.preload(model: model, request: app.request)
    }

    /// Distilled MLX models need very different steps/guidance (Z-Image Turbo: 9 steps,
    /// guidance 0) from SD's 25 / 7.5, so switching models resets them.
    private func applyDefaults(previous: InstalledModel?) {
        if app.isRestoring {
            app.isRestoring = false
            return
        }
        guard let model = selectedModel else { return }
        // Fast mode belongs to one model family (the MOSS LoRA also passes as a LoRA for
        // MOSS-Image base, which it wasn't trained for): drop it when switching away.
        let otherFastPaths = Set(MLXFamilies.all.compactMap { $0.fastLoRA?.localURL.path })
            .subtracting([model.fastLoRA?.localURL.path].compactMap { $0 })
        app.request.loras?.removeAll { otherFastPaths.contains($0.source) }
        // An MLX model that takes no LoRAs (Iris-3B) would fail to load with any.
        if model.kind == .mlx, model.loraBase == nil { app.request.loras = [] }
        if model.defaults != nil || previous?.defaults != nil {
            applyRecommended(for: model)
        }
    }

    private func isRecommended(for model: InstalledModel) -> Bool {
        let r = recommended(for: model)
        return app.request.steps == r.steps && app.request.guidance == r.guidance
            && (model.kind == .mlx || app.request.scheduler == .dpmSolver)
    }

    private func applyRecommended(for model: InstalledModel) {
        let r = recommended(for: model)
        app.request.steps = r.steps
        app.request.guidance = r.guidance
        if model.kind != .mlx { app.request.scheduler = .dpmSolver }
    }

    // MARK: Prompt enhancer

    private func availabilityHelp(_ availability: PromptEnhancer.Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "Rewrite the prompt with more detail using \(PromptEnhancer.engineDescription), on device (⌘E). Press again for another version."
    }

    private func enhance() {
        // Undo always goes back to what the user wrote, even after several enhances.
        let original = beforeEnhance ?? PromptEnhancer.Result(prompt: app.request.prompt,
                                                             negativePrompt: app.request.negativePrompt)
        let model = selectedModel
        enhancing = true
        enhanceError = nil
        Task {
            do {
                let result = try await PromptEnhancer.enhance(prompt: original.prompt,
                                                              negativePrompt: original.negativePrompt,
                                                              for: model)
                lastEnhanced = result.prompt
                app.request.prompt = result.prompt
                app.request.negativePrompt = result.negativePrompt
                beforeEnhance = original
            } catch {
                enhanceError = error.localizedDescription
            }
            enhancing = false
        }
    }

    // MARK: Viewer

    /// The finished image being looked at: one picked in the gallery or queue, else the latest.
    private var shownRecord: GenerationRecord? {
        if let viewed = app.viewedRecord { return viewed }
        guard let latest = generator.lastRecord, !trashed.contains(latest.fileName) else { return nil }
        return latest
    }

    /// The live preview, unless previews were turned off while this picture was being made.
    private var preview: CGImage? {
        previewEvery > 0 ? generator.preview : nil
    }

    private var shownImage: CGImage? {
        if let preview { return preview }
        if app.viewedRecord != nil { return viewedImage }
        return shownRecord == nil ? nil : generator.lastImage
    }

    private var viewer: some View {
        VStack(spacing: 0) {
            viewerToolbar
            progressLine
            ZStack {
                Theme.base
                if let image = shownImage {
                    ZoomableImage(image: image, state: zoom, inset: 16, cornerRadius: 6) {
                        guard let record = shownRecord else { return NSItemProvider() }
                        return NSItemProvider(contentsOf: fileURL(record)) ?? NSItemProvider()
                    }
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                    .opacity(preview != nil ? 0.8 : 1)
                } else if generator.phase != .idle {
                    ProgressView().controlSize(.large)
                } else {
                    ContentUnavailableView("Your picture will appear here", systemImage: "photo.artframe",
                                           description: Text("Write a prompt on the left, then press Create (⌘↩)."))
                }
            }
            .overlay(alignment: .topLeading) {
                if showInfo, let record = shownRecord, preview == nil {
                    InfoOverlay(record: record, image: shownImage, isMLX: store.model(id: record.modelID)?.kind == .mlx)
                        .padding(14)
                }
            }
            .overlay(alignment: .topTrailing) {
                if shownImage != nil {
                    HStack(spacing: 2) { ZoomControls(state: zoom) }
                        .padding(4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                        .padding(14)
                }
            }
            .overlay(alignment: .bottom) { statusPill.padding(14) }
        }
        .background(Theme.base)
        .onChange(of: shownRecord?.fileName) { zoom.fit() }
        .task(id: app.viewedRecord?.fileName) {
            guard let record = app.viewedRecord else { viewedImage = nil; return }
            let path = fileURL(record).path
            viewedImage = await Task.detached { StartImages.load(path) }.value
        }
        .confirmationDialog("Move this picture to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                if let record = shownRecord { trash(record) }
            }
        }
        .alert("Couldn't move the picture to the Trash", isPresented: Binding(
            get: { trashError != nil }, set: { if !$0 { trashError = nil } }
        )) {
            Button("OK") { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
    }

    /// Actions on the picture being shown, in a row above it.
    private var viewerToolbar: some View {
        let record = shownRecord
        return HStack(spacing: 4) {
            if app.viewedRecord != nil, generator.lastRecord != nil {
                Button("Latest", systemImage: "arrow.left") { app.viewedRecord = nil }
                    .controlSize(.small)
                    .help("Back to the most recent picture")
                    .padding(.leading, 10)
            }
            UpscaleStatus().padding(.leading, 10)
            Spacer(minLength: 0)
            Group {
                Button("Use Prompt", systemImage: "text.quote") {
                    if let r = record?.request {
                        app.request.prompt = r.prompt
                        app.request.negativePrompt = r.negativePrompt
                    }
                }
                .help("Use this picture's prompt")
                Button("Use Seed", systemImage: "leaf") {
                    if let seed = record?.request.seed {
                        app.request.seed = seed
                        randomSeed = false
                    }
                }
                .help("Use this picture's seed (and stop picking a new one each time)")
                Button("Use All", systemImage: "arrow.uturn.backward") { if let record { app.restore(record) } }
                    .help("Use all of this picture's settings, including the model")
                toolbarDivider
                Button("Edit This Picture", systemImage: "photo.badge.arrow.down") {
                    if let record { app.useAsStartImage(fileURL(record), for: selectedModel) }
                }
                .help("Use as the start image, to change it with a new prompt")
                UpscaleMenu(records: record.map { [$0] } ?? []) {
                    Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Make a bigger, sharper copy: 2× or 4× with Real-ESRGAN")
                toolbarDivider
                Button("Info", systemImage: "info.circle") { showInfo.toggle() }
                    .buttonStyle(IconButtonStyle(isSelected: showInfo))
                    .keyboardShortcut("i", modifiers: .command)
                    .help("Show how this picture was made (⌘I)")
                toolbarDivider
                Button("Copy", systemImage: "doc.on.doc") { copyShownImage() }
                    .help("Copy the picture")
                Button("Save…", systemImage: "square.and.arrow.down") { if let record { save(record) } }
                    .help("Save a copy somewhere else")
                if let record {
                    ShareLink(item: fileURL(record)) { Label("Share", systemImage: "square.and.arrow.up") }
                        .help("Share")
                }
                Button("Show in Finder", systemImage: "folder") {
                    if let record { NSWorkspace.shared.activateFileViewerSelecting([fileURL(record)]) }
                }
                .help("Show in Finder")
                toolbarDivider
                Button("Move to Trash", systemImage: "trash") { confirmTrash = true }
                    .help("Move to Trash")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(record == nil || preview != nil)
            Spacer(minLength: 0)
            Button(previewEvery > 0 ? "Turn Off Live Preview" : "Turn On Live Preview",
                   systemImage: previewEvery > 0 ? "eye" : "eye.slash") {
                if previewEvery > 0 {
                    lastPreviewEvery = previewEvery
                    previewEvery = 0
                } else {
                    previewEvery = max(lastPreviewEvery, 1)
                }
            }
            .buttonStyle(IconButtonStyle(isSelected: previewEvery > 0))
            .help(previewEvery > 0
                  ? "Live preview is on (every \(previewEvery) steps). Click to turn it off: pictures finish a little faster"
                  : "Live preview is off. Click to watch the picture form, from its next preview step")
            Button(showGallery ? "Hide Gallery" : "Show Gallery", systemImage: "sidebar.right") {
                withAnimation { showGallery.toggle() }
            }
            .buttonStyle(IconButtonStyle(isSelected: showGallery))
            .help(showGallery ? "Hide the gallery panel" : "Show the gallery panel")
            .padding(.trailing, 6)
        }
        .frame(maxWidth: .infinity, minHeight: HeaderBar<EmptyView>.height, maxHeight: HeaderBar<EmptyView>.height)
        .background(Theme.panel, ignoresSafeAreaEdges: [])
    }

    private var toolbarDivider: some View {
        Divider().frame(height: 18).padding(.horizontal, 4)
    }

    /// A thin bar under the toolbar showing progress through the steps.
    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.border)
                switch generator.phase {
                case .idle:
                    EmptyView()
                case .loading:
                    Rectangle().fill(Theme.accent.opacity(0.5))
                        .frame(width: geo.size.width * 0.3)
                        .phaseAnimator([0.0, 1.0]) { bar, phase in
                            bar.offset(x: phase * geo.size.width * 0.7)
                        } animation: { _ in .easeInOut(duration: 1.1) }
                case .generating(let step, let total):
                    Rectangle().fill(Theme.accent)
                        .frame(width: geo.size.width * Double(step) / Double(max(total, 1)))
                        .animation(.easeOut(duration: 0.3), value: step)
                }
            }
        }
        .frame(height: 3)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch generator.phase {
        case .idle:
            if let error = generator.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .pill()
            }
        case .loading(let name):
            Text("Getting \(name) ready… The first time can take a few minutes.")
                .pill()
        case .generating(let step, let total):
            HStack(spacing: 4) {
                Text("Step \(step) of \(total)").monospacedDigit()
                if let eta = generator.etaSeconds, eta >= 1 {
                    Text("· about \(Duration.seconds(eta.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) left")
                        .foregroundStyle(.secondary)
                }
            }
            .pill()
        }
    }

    // MARK: Gallery actions

    private func select(_ record: GenerationRecord) {
        app.viewedRecord = record == generator.lastRecord ? nil : record
        trashed.remove(record.fileName)
    }

    private func trash(_ record: GenerationRecord) {
        let index = records.firstIndex(of: record)
        do {
            try ImageSaver.delete(record)
        } catch {
            trashError = error.localizedDescription
            return
        }
        trashed.insert(record.fileName)
        records.removeAll { $0 == record }
        guard record == shownRecord else { return }
        // Show the next picture along, as a photo viewer would.
        if let index, !records.isEmpty {
            let next = records[min(index, records.count - 1)]
            app.viewedRecord = next == generator.lastRecord ? nil : next
        } else {
            app.viewedRecord = nil
        }
    }

    private func fileURL(_ record: GenerationRecord) -> URL {
        ImageSaver.folder.appending(path: record.fileName)
    }

    private func save(_ record: GenerationRecord) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = record.fileName
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.copyItem(at: fileURL(record), to: destination)
    }

    private func copyShownImage() {
        guard let image = (app.viewedRecord != nil ? viewedImage : nil) ?? generator.lastImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }
}

private extension View {
    /// A small floating label over the image.
    func pill() -> some View {
        font(.callout)
            .lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.border))
    }
}

// MARK: - Info overlay

/// How the shown picture was made, floating over its top-left corner.
private struct InfoOverlay: View {
    let record: GenerationRecord
    let image: CGImage?
    let isMLX: Bool

    var body: some View {
        let r = record.request
        VStack(alignment: .leading, spacing: 8) {
            Text(r.prompt)
                .lineLimit(8)
                .textSelection(.enabled)
            if !r.negativePrompt.isEmpty {
                Text("Avoid: \(r.negativePrompt)")
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                row("Model", record.modelName)
                row("Seed", String(r.seed))
                row("Steps", "\(r.steps)")
                row("Guidance", r.guidance.formatted(.number.precision(.fractionLength(1))))
                if !isMLX { row("Scheduler", r.scheduler.rawValue) }
                if let image { row("Size", "\(image.width) × \(image.height)") }
                if let up = record.upscale {
                    row("Upscaled", "\(up.scale)× with \(up.model), \(up.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                }
                if let loras = r.loras, !loras.isEmpty {
                    row("LoRAs", loras.map { "\($0.name) × \($0.scale.formatted(.number.precision(.fractionLength(2))))" }
                        .joined(separator: ", "))
                }
                if r.isImageToImage {
                    row("Start image", "change \((r.change ?? 0.6).formatted(.number.precision(.fractionLength(2))))")
                }
                if let ratio = r.stepCacheRatio {
                    row("Skipped steps", "\(Int(ratio * 100))% near-identical steps reused")
                }
                if let faster = r.fasterGPUMaths {
                    row("GPU maths", faster ? "16-bit (faster)" : "32-bit")
                }
                row("Time", "\(record.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                row("Made", record.date.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.caption)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

// MARK: - Gallery panel

/// Recent pictures beside the image; click one to look at it.
private struct GalleryPanel: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    let records: [GenerationRecord]
    let selected: GenerationRecord?
    let onSelect: (GenerationRecord) -> Void
    let onTrash: (GenerationRecord) -> Void

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Gallery").font(.headline)
                Text("\(records.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open My Pictures", systemImage: "arrow.up.left.and.arrow.down.right") { app.section = .gallery }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Open all pictures, with search and a full-size viewer")
            }
            .padding(.horizontal, 12)
            .frame(height: HeaderBar<EmptyView>.height)
            Divider()
            if records.isEmpty {
                ContentUnavailableView("No pictures yet", systemImage: "photo.on.rectangle",
                                       description: Text("Pictures you create show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(records) { record in
                            Thumbnail(record: record, isSelected: record == selected)
                                .onTapGesture { onSelect(record) }
                                .contextMenu {
                                    Button("Use All Settings") { app.restore(record) }
                                    Button("Edit This Picture") {
                                        app.useAsStartImage(ImageSaver.folder.appending(path: record.fileName),
                                                            for: store.model(id: app.selectedModelID))
                                    }
                                    UpscaleMenu(records: [record]) { Text("Upscale") }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([ImageSaver.folder.appending(path: record.fileName)])
                                    }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) { onTrash(record) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Theme.panel, ignoresSafeAreaEdges: [])
    }
}

private struct Thumbnail: View {
    let record: GenerationRecord
    let isSelected: Bool
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.raised)
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(record.request.prompt)
        .task(id: record.fileName) {
            let record = record
            image = await Task.detached { ImageSaver.thumbnail(for: record, maxPixels: 256) }.value
        }
    }
}

// MARK: - Quality

/// Steps as a simple choice, relative to what the model is tuned for.
enum Quality: String, CaseIterable, Identifiable {
    case quick = "Quick"
    case standard = "Standard"
    case extra = "Extra Detail"

    var id: String { rawValue }

    func steps(for recommended: ModelDefaults) -> Int {
        let factor = switch self {
        case .quick: 0.6
        case .standard: 1.0
        case .extra: 1.5
        }
        return max(1, Int((Double(recommended.steps) * factor).rounded()))
    }
}

extension AspectChoice {
    var friendlyName: String {
        switch self {
        case .square: "Square"
        case .portrait: "Portrait (3:4)"
        case .landscape: "Landscape (4:3)"
        case .wide: "Widescreen (16:9)"
        case .tall: "Phone (9:16)"
        }
    }

}

// MARK: - Styles

/// One-click styles. Each adds a visible phrase to the description, so it's clear what
/// it does and can be edited; picking another style swaps the phrase.
private struct StyleChips: View {
    @Binding var prompt: String

    private static let styles: [(name: String, icon: String, phrase: String)] = [
        ("Photo", "camera", "film photo"),
        ("Cinematic", "film", "cinematic still, dramatic lighting"),
        ("Watercolor", "drop", "watercolor painting"),
        ("Oil Painting", "paintbrush", "oil painting"),
        ("Anime", "sparkle", "anime illustration"),
        ("3D", "cube", "3D render"),
        ("Pixel Art", "square.grid.3x3", "pixel art"),
        ("Sketch", "pencil", "pencil sketch"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Style").font(.caption).foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Self.styles, id: \.name) { style in
                    let active = prompt.localizedCaseInsensitiveContains(style.phrase)
                    Button {
                        toggle(style.phrase, active: active)
                    } label: {
                        Label(style.name, systemImage: style.icon)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(active ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12),
                                        in: Capsule())
                            .overlay(Capsule().strokeBorder(active ? Color.accentColor : .clear))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(active ? "Remove “\(style.phrase)”" : "Add “\(style.phrase)” to the description")
                }
            }
        }
    }

    private func toggle(_ phrase: String, active: Bool) {
        var text = prompt
        // Styles are exclusive: take out any other style phrase first.
        for style in Self.styles where style.phrase == phrase || !active {
            text = removing(style.phrase, from: text)
        }
        if !active {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? phrase : "\(trimmed), \(phrase)"
        }
        prompt = text
    }

    private func removing(_ phrase: String, from text: String) -> String {
        var text = text
        for variant in [", \(phrase)", "\(phrase), ", phrase] {
            text = text.replacingOccurrences(of: variant, with: "", options: .caseInsensitive)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var y: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

// MARK: - Surprise Me

private enum SurprisePrompts {
    static let all = [
        "a lighthouse on a rocky cliff during a storm, crashing waves, moody sky",
        "a tiny dragon curled up asleep in a teacup, soft morning light",
        "a bustling night market in Tokyo, neon signs reflected in puddles",
        "an astronaut tending a vegetable garden on the moon, earth in the sky",
        "a fox in a knitted scarf reading a book under an autumn tree",
        "a floating island with a waterfall pouring into the clouds",
        "a vintage red bicycle leaning against a flower-covered wall in Italy",
        "a cozy treehouse library with lanterns, books stacked everywhere",
        "a whale swimming through the sky above a quiet seaside village",
        "a steaming bowl of ramen on a wooden counter, close-up, shallow depth of field",
        "a polar bear wearing sunglasses on a beach chair, bright summer day",
        "an ancient temple overgrown with jungle vines, rays of sunlight through mist",
    ]

    static func next(after current: String) -> String {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }
}

// MARK: - Welcome

/// Shown in Create until a model is installed: one button to get a good first model.
private struct WelcomeView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store

    private var starter: CatalogEntry? {
        ModelCatalog.entries.first { $0.id == ModelBlurb.starterID }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Make pictures from words").font(.largeTitle.bold())
                Text("Describe anything and your Mac draws it, privately and offline.\nFirst, get a model: it's what draws the pictures.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            if let starter {
                starterCard(starter)
            }
            Button("Browse All Models") {
                app.section = .models
            }
            .buttonStyle(.link)
            if let error = store.lastError {
                Text(error).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func starterCard(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline)
                    Text(ModelBlurb.tagline(id: entry.id, kind: entry.kind, notes: entry.notes))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(entry.approxGB.formatted(.number.precision(.fractionLength(1)))) GB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let download = store.downloads[entry.id] {
                ProgressView(value: download.fraction) {
                    Text("Downloading… \(Int(download.fraction * 100))%").font(.caption)
                }
                HStack {
                    Text("You only need to do this once.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { store.cancelDownload(entry) }
                }
            } else {
                Button {
                    store.lastError = nil
                    store.download(entry)
                } label: {
                    Label("Download and Get Started", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(16)
        .frame(maxWidth: 420)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
