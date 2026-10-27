import SwiftUI

struct GenerateView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @Environment(GenerationQueue.self) private var queue
    @AppStorage("previewEvery") private var previewEvery = 5
    @AppStorage("batchCount") private var batchCount = 1
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
        HSplitView {
            controls
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 420)
            output
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Generate")
    }

    // MARK: Controls

    private var controls: some View {
        @Bindable var app = app
        return Form {
            Picker("Model", selection: Binding(
                get: { selectedModel?.id },
                set: { app.selectedModelID = $0 }
            )) {
                if runnableModels.isEmpty { Text("No models installed").tag(String?.none) }
                ForEach(runnableModels) { model in
                    Text(model.name).tag(Optional(model.id))
                }
            }
            if let selectedModel {
                if selectedModel.kind.hasFixedSize {
                    LabeledContent("Output", value: "\(selectedModel.resolution) × \(selectedModel.resolution)")
                    LabeledContent("Compute", value: selectedModel.computeUnits.label)
                } else {
                    let size = (app.request.aspect ?? .square).size(base: selectedModel.resolution)
                    Picker("Aspect", selection: Binding(
                        get: { app.request.aspect ?? .square },
                        set: { app.request.aspect = $0 }
                    )) {
                        ForEach(AspectChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Output", value: "\(size.width) × \(size.height)")
                    LabeledContent("Compute", value: "GPU (MLX, float16)")
                }
                if let loras = selectedModel.loras, !loras.isEmpty {
                    LabeledContent("LoRA", value: loras.map(\.label).joined(separator: ", "))
                        .help("Fused into this model at conversion. Add the LoRA's trigger words to your prompt.")
                }
            }

            Section("Prompt") {
                TextEditor(text: $app.request.prompt)
                    .font(.body)
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                if selectedModel?.defaults?.supportsNegativePrompt ?? true {
                    TextField("Negative prompt", text: $app.request.negativePrompt, axis: .vertical)
                        .lineLimit(2...4)
                }
                enhanceRow
            }

            if let selectedModel, selectedModel.kind == .mlx {
                MLXLoRASection(model: selectedModel, loras: Binding(
                    get: { app.request.loras ?? [] },
                    set: { app.request.loras = $0 }
                ))
            }

            Section("Settings") {
                if let selectedModel {
                    recommendedRow(for: selectedModel)
                }
                Stepper("Steps: \(app.request.steps)", value: $app.request.steps, in: 1...100)
                VStack(alignment: .leading) {
                    Text("Guidance: \(app.request.guidance, specifier: "%.1f")")
                    Slider(value: $app.request.guidance, in: 0...20, step: 0.5)
                }
                HStack {
                    TextField("Seed", value: $app.request.seed, format: .number.grouping(.never))
                    Button {
                        app.request.randomizeSeed()
                    } label: {
                        Image(systemName: "dice")
                    }
                    .help("Random seed")
                }
                if selectedModel?.kind != .mlx {
                    Picker("Scheduler", selection: $app.request.scheduler) {
                        ForEach(SchedulerChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
            }

            Section {
                Stepper(value: $batchCount, in: 1...50) {
                    Text(batchCount == 1 ? "Images: 1" : "Images: \(batchCount) (seeds \(app.request.seed)–\(app.request.seed &+ UInt32(batchCount - 1)))")
                }
                Button {
                    guard let model = selectedModel else { return }
                    queue.enqueue(model: model, request: app.request, count: batchCount, previewEvery: previewEvery)
                } label: {
                    Text(queue.isRunning ? "Add to Queue" : (batchCount == 1 ? "Generate" : "Generate \(batchCount)"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedModel == nil || app.request.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                if queue.isRunning {
                    HStack {
                        Button("Cancel Current", role: .cancel) { queue.cancelCurrent() }
                        if queue.pendingCount > 0 {
                            Button("Cancel All (\(queue.pendingCount + 1))", role: .destructive) { queue.cancelAll() }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedModel?.id) { oldID, _ in
            applyDefaults(previous: store.model(id: oldID))
        }
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
                Button("Use Recommended") { applyRecommended(for: model) }
                    .help("Set steps, guidance\(model.kind == .mlx ? "" : " and scheduler") to what \(model.name) is tuned for")
            }
        }
    }

    // MARK: Prompt enhancer

    private var enhanceRow: some View {
        let availability = PromptEnhancer.availability
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    enhance()
                } label: {
                    Label("Enhance", systemImage: "sparkles")
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
            if case .unavailable(let reason) = availability {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            } else if let enhanceError {
                Text(enhanceError).font(.caption).foregroundStyle(.red)
            }
        }
        .onChange(of: app.request.prompt) {
            // A manual edit becomes the new starting point for the next enhance.
            if app.request.prompt != lastEnhanced { beforeEnhance = nil }
        }
    }

    private func availabilityHelp(_ availability: PromptEnhancer.Availability) -> String {
        if case .unavailable(let reason) = availability { return reason }
        return "Rewrite the prompt with more detail using Apple Intelligence, on device (⌘E). Press again for another variation."
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

    private var output: some View {
        VStack(spacing: 12) {
            status
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5))
                if let image = generator.preview ?? generator.lastImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(8)
                        .opacity(generator.preview != nil ? 0.75 : 1)
                } else {
                    ContentUnavailableView("No image yet", systemImage: "photo",
                                           description: Text("Write a prompt and press ⌘↩."))
                }
            }
            if let record = generator.lastRecord, !generator.isBusy {
                HStack {
                    Text("\(record.modelName) · seed \(record.request.seed) · \(record.seconds, specifier: "%.1f") s")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                    Button("Copy") { copyLastImage() }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ImageSaver.folder.appending(path: record.fileName)])
                    }
                }
            }
            if !queue.jobs.isEmpty {
                QueueView()
                    .frame(maxHeight: 220)
            }
        }
        .padding()
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
                Text("Loading \(name)… (the first load compiles for this Mac and can take a few minutes)")
            }
            .progressViewStyle(.linear)
        case .generating(let step, let total):
            ProgressView(value: Double(step), total: Double(max(total, 1))) {
                Text("Step \(step) of \(total)")
            }
        }
    }

    private func copyLastImage() {
        guard let image = generator.lastImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: .zero)])
    }
}
