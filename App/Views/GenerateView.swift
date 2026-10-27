import SwiftUI
import UniformTypeIdentifiers

struct GenerateView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @Environment(GenerationQueue.self) private var queue
    @AppStorage("previewEvery") private var previewEvery = 5
    @AppStorage("batchCount") private var batchCount = 1
    @AppStorage("randomSeed") private var randomSeed = true
    @AppStorage("preloadModels") private var preloadModels = true
    @AppStorage("showAdvancedOptions") private var showAdvanced = false
    @State private var viewedImage: CGImage?
    @State private var enhancing = false
    @State private var beforeEnhance: PromptEnhancer.Result?
    @State private var enhanceError: String?
    @State private var lastEnhanced: String?

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
                    controls
                        .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
                    output
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Create")
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var app = app
        return Form {
            Section {
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
                            .help("Fused into this model at conversion. Add the LoRA's trigger words to your description.")
                    }
                }
            }

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
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                }
                promptTools
                StyleChips(prompt: $app.request.prompt)
            } header: {
                Text("Describe your picture")
            }

            Section("Picture") {
                shapeRow
                if let selectedModel {
                    qualityRow(for: selectedModel)
                }
                Stepper(value: $batchCount, in: 1...50) {
                    Text(batchCount == 1 ? "Make 1 picture" : "Make \(batchCount) pictures")
                }
                .help(batchCount == 1 || randomSeed ? "" :
                      "Variations \(app.request.seed)–\(app.request.seed &+ UInt32(batchCount - 1))")
            }

            StartImageSection(model: selectedModel)
            if let error = app.startImageError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            Section {
                Toggle("Show advanced options", isOn: $showAdvanced.animation())
            }
            if showAdvanced {
                advanced
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) { createBar }
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

    private var promptTools: some View {
        let availability = PromptEnhancer.availability
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    app.request.prompt = SurprisePrompts.next(after: app.request.prompt)
                } label: {
                    Label("Surprise Me", systemImage: "dice")
                }
                .help("Fill in an example description")

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
                    ForEach(AspectChoice.allCases) { aspect in
                        Label(aspect.friendlyName, systemImage: aspect.icon).tag(aspect)
                    }
                }
                .help("\(size.width) × \(size.height) pixels")
            }
        }
    }

    private func qualityRow(for model: InstalledModel) -> some View {
        let recommended = model.recommended
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Quality", selection: Binding<Quality?>(
                get: { Quality.allCases.first { $0.steps(for: recommended) == app.request.steps } },
                set: { if let quality = $0 { app.request.steps = quality.steps(for: recommended) } }
            )) {
                ForEach(Quality.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            Text(Quality.allCases.contains { $0.steps(for: recommended) == app.request.steps }
                 ? "\(app.request.steps) steps. More steps take longer and add detail."
                 : "Custom: \(app.request.steps) steps (set in advanced options)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Advanced

    @ViewBuilder
    private var advanced: some View {
        @Bindable var app = app
        if selectedModel?.defaults?.supportsNegativePrompt ?? true {
            Section("Things to avoid") {
                TextField("Things to avoid", text: $app.request.negativePrompt,
                          prompt: Text("blurry, extra fingers, text"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...4)
            }
        }

        Section("Fine-tuning") {
            if let selectedModel {
                recommendedRow(for: selectedModel)
            }
            Stepper("Steps: \(app.request.steps)", value: $app.request.steps, in: 1...100)
            VStack(alignment: .leading) {
                Text("How closely to follow the description: \(app.request.guidance, specifier: "%.1f")")
                Slider(value: $app.request.guidance, in: 0...20, step: 0.5)
            }
            .help("Guidance. Higher follows the words more literally; too high looks harsh.")
            HStack {
                TextField("Variation number", value: $app.request.seed, format: .number.grouping(.never))
                    .disabled(randomSeed)
                Button {
                    app.request.randomizeSeed()
                } label: {
                    Image(systemName: "dice")
                }
                .help("Pick a random variation")
                .disabled(randomSeed)
            }
            .help("The seed. The same description, settings and variation number give the same picture.")
            Toggle("New variation each time", isOn: $randomSeed)
                .help("Off: keep the variation number to tweak one picture by changing only the description or settings")
            if let selectedModel {
                if selectedModel.kind == .mlx {
                    LabeledContent("Runs on", value: "GPU (MLX, float16)")
                } else {
                    Picker("Scheduler", selection: $app.request.scheduler) {
                        ForEach(SchedulerChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Runs on", value: selectedModel.computeUnits.label)
                }
            }
        }

        if let selectedModel, selectedModel.kind == .mlx {
            MLXLoRASection(model: selectedModel, loras: Binding(
                get: { app.request.loras ?? [] },
                set: { app.request.loras = $0 }
            ))
        }
    }

    private func recommendedRow(for model: InstalledModel) -> some View {
        let r = model.recommended
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

    // MARK: Create button

    private var canCreate: Bool {
        selectedModel != nil && !app.request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var createBar: some View {
        VStack(spacing: 8) {
            Button {
                guard let model = selectedModel else { return }
                // The seed field shows the seed actually used, so it can be kept or reused.
                if randomSeed { app.request.randomizeSeed() }
                queue.enqueue(model: model, request: app.request, count: batchCount, previewEvery: previewEvery)
            } label: {
                Label(createTitle, systemImage: queue.isRunning ? "text.badge.plus" : "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCreate)
            .help(canCreate ? "⌘↩" : "Describe your picture first")

            if queue.isRunning {
                HStack {
                    Button("Stop This Picture", role: .cancel) { queue.cancelCurrent() }
                        .keyboardShortcut(.cancelAction)
                        .help("Stop the picture being made (Esc); the rest still get made")
                    if queue.pendingCount > 0 {
                        Button("Stop All (\(queue.pendingCount + 1))", role: .destructive) { queue.cancelAll() }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var createTitle: String {
        if queue.isRunning { return "Add to Queue" }
        return batchCount == 1 ? "Create Picture" : "Create \(batchCount) Pictures"
    }

    // MARK: Model defaults

    /// Loads the selected model shortly after it's picked, so Create starts at once
    /// instead of waiting 5–10 s (MLX) or minutes (a Core ML model's first compile).
    private func preloadSelectedModel() async {
        guard preloadModels, !app.automationRunning, let model = selectedModel else { return }
        try? await Task.sleep(for: .seconds(1.5))  // don't load every model clicked past
        guard !Task.isCancelled, !queue.isRunning, !generator.isBusy,
              generator.loadedModelID != model.id else { return }
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
        if model.defaults != nil || previous?.defaults != nil {
            applyRecommended(for: model)
        }
    }

    private func isRecommended(for model: InstalledModel) -> Bool {
        let r = model.recommended
        return app.request.steps == r.steps && app.request.guidance == r.guidance
            && (model.kind == .mlx || app.request.scheduler == .dpmSolver)
    }

    private func applyRecommended(for model: InstalledModel) {
        let r = model.recommended
        app.request.steps = r.steps
        app.request.guidance = r.guidance
        if model.kind != .mlx { app.request.scheduler = .dpmSolver }
    }

    // MARK: Prompt enhancer

    private func availabilityHelp(_ availability: PromptEnhancer.Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "Rewrite the description with more detail using Apple Intelligence, on device (⌘E). Press again for another version."
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

    // MARK: Output

    /// The finished image being looked at: a queue job the user clicked, else the latest.
    private var shownRecord: GenerationRecord? {
        app.viewedRecord ?? generator.lastRecord
    }

    private var shownImage: CGImage? {
        generator.preview ?? (app.viewedRecord != nil ? viewedImage : nil) ?? generator.lastImage
    }

    private var output: some View {
        VStack(spacing: 12) {
            status
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5))
                if let image = shownImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                        .padding(12)
                        .opacity(generator.preview != nil ? 0.75 : 1)
                        .onDrag {
                            guard let record = shownRecord else { return NSItemProvider() }
                            return NSItemProvider(contentsOf: fileURL(record)) ?? NSItemProvider()
                        }
                } else if generator.phase != .idle {
                    ProgressView().controlSize(.large)
                } else {
                    ContentUnavailableView("Your picture will appear here", systemImage: "photo.artframe",
                                           description: Text("Describe what you'd like to see, then press Create Picture (⌘↩)."))
                }
            }
            if let record = shownRecord, generator.preview == nil {
                actions(for: record)
            }
            if !queue.jobs.isEmpty {
                QueueView()
                    .frame(maxHeight: 220)
            }
        }
        .padding()
        .task(id: app.viewedRecord?.fileName) {
            guard let record = app.viewedRecord else { viewedImage = nil; return }
            let path = fileURL(record).path
            viewedImage = await Task.detached { StartImages.load(path) }.value
        }
        .onChange(of: generator.lastRecord) { app.viewedRecord = nil }
    }

    private func actions(for record: GenerationRecord) -> some View {
        HStack {
            Text("\(record.modelName) · \(record.seconds, specifier: "%.0f") s")
                .foregroundStyle(.secondary)
                .font(.callout)
                .lineLimit(1)
                .help("Variation \(record.request.seed)")
            Spacer()
            if app.viewedRecord != nil {
                Button("Latest") { app.viewedRecord = nil }
                    .help("Back to the most recent picture")
            }
            Button("Save…", systemImage: "square.and.arrow.down") { save(record) }
            ShareLink(item: fileURL(record)) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button("Copy", systemImage: "doc.on.doc") { copyShownImage() }
            Menu {
                Button("Edit This Picture", systemImage: "photo.badge.arrow.down") {
                    app.useAsStartImage(fileURL(record), for: selectedModel)
                }
                Button("Reuse These Settings", systemImage: "arrow.uturn.backward") { app.restore(record) }
                Divider()
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL(record)])
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.large)
    }

    @ViewBuilder
    private var status: some View {
        switch generator.phase {
        case .idle:
            if let error = generator.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .loading(let name):
            ProgressView {
                Text("Getting \(name) ready… The first time can take a few minutes.")
            }
            .progressViewStyle(.linear)
        case .generating(let step, let total):
            ProgressView(value: Double(step), total: Double(max(total, 1))) {
                HStack {
                    Text("Creating your picture: step \(step) of \(total)")
                    if let eta = generator.etaSeconds, eta >= 1 {
                        Text("· about \(Duration.seconds(eta.rounded()).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))) left")
                            .foregroundStyle(.secondary)
                    }
                }
            }
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

    var icon: String {
        switch self {
        case .square: "square"
        case .portrait: "rectangle.portrait"
        case .landscape: "rectangle"
        case .wide: "rectangle.ratio.16.to.9"
        case .tall: "rectangle.ratio.9.to.16"
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
