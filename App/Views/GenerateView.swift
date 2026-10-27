import SwiftUI

struct GenerateView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @AppStorage("previewEvery") private var previewEvery = 5
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
                LabeledContent("Output", value: "\(selectedModel.resolution) × \(selectedModel.resolution)")
                LabeledContent("Compute", value: selectedModel.computeUnits.label)
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
                TextField("Negative prompt", text: $app.request.negativePrompt, axis: .vertical)
                    .lineLimit(2...4)
                enhanceRow
            }

            Section("Settings") {
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
                Picker("Scheduler", selection: $app.request.scheduler) {
                    ForEach(SchedulerChoice.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section {
                if generator.isBusy {
                    Button("Cancel", role: .cancel) { generator.cancel() }
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        guard let model = selectedModel else { return }
                        let request = app.request
                        Task { await generator.generate(model: model, request: request, previewEvery: previewEvery) }
                    } label: {
                        Text("Generate").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(selectedModel == nil || app.request.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
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
