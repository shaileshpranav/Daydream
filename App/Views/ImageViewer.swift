import SwiftUI

/// Full-size view of a gallery image: zoomable image on the left, everything about how it
/// was made on the right. ← → move through the gallery, Esc closes.
struct ImageViewer: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    let records: [GenerationRecord]
    @Binding var index: Int?
    let onTrash: (GenerationRecord) -> Void

    @State private var zoom = ZoomState()
    @State private var image: CGImage?
    @State private var confirmTrash = false

    private var record: GenerationRecord? {
        guard let index, records.indices.contains(index) else { return nil }
        return records[index]
    }

    var body: some View {
        if let record {
            VStack(spacing: 0) {
                headerBar
                HSplitView {
                    imageArea(record)
                        .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.base)
                    InfoPanel(record: record, image: image, confirmTrash: $confirmTrash)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
            }
            .task(id: record.fileName) {
                image = ImageSaver.thumbnail(for: record)  // instant, then the full image
                let path = ImageSaver.folder.appending(path: record.fileName).path
                let full = await Task.detached { StartImages.load(path) }.value
                if self.record == record { image = full }
            }
            .confirmationDialog("Move this image to the Trash?", isPresented: $confirmTrash) {
                Button("Move to Trash", role: .destructive) { onTrash(record) }
            }
        }
    }

    // MARK: Image

    private func imageArea(_ record: GenerationRecord) -> some View {
        ZoomableImage(image: image, state: zoom,
                      dragItem: { NSItemProvider(contentsOf: ImageSaver.folder.appending(path: record.fileName)) ?? NSItemProvider() })
            .overlay {
                if image == nil { ProgressView() }
            }
    }

    // MARK: Header

    private var headerBar: some View {
        HeaderBar {
            Button("Back to My Pictures", systemImage: "chevron.backward") { index = nil }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(IconButtonStyle())
                .help("Back to all pictures (Esc)")
            Text("My Pictures").font(.headline)
            Spacer()
            Group {
                Button("Previous", systemImage: "arrow.left") { step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled((index ?? 0) <= 0)
                Text("\((index ?? 0) + 1) of \(records.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button("Next", systemImage: "arrow.right") { step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled((index ?? 0) >= records.count - 1)
                Divider().frame(height: 18).padding(.horizontal, 4)
            }
            .buttonStyle(IconButtonStyle())
            ZoomControls(state: zoom)
        }
    }

    private func step(_ offset: Int) {
        guard let index else { return }
        let next = index + offset
        if records.indices.contains(next) {
            self.index = next
        }
    }
}

/// How an image was made, and what to do with it.
private struct InfoPanel: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    let record: GenerationRecord
    let image: CGImage?
    @Binding var confirmTrash: Bool

    private var url: URL { ImageSaver.folder.appending(path: record.fileName) }

    var body: some View {
        let r = record.request
        Form {
            Section("Prompt") {
                Text(r.prompt).textSelection(.enabled)
                if !r.negativePrompt.isEmpty {
                    LabeledContent("Negative") { Text(r.negativePrompt).textSelection(.enabled) }
                }
            }
            Section("Settings") {
                LabeledContent("Model", value: record.modelName)
                LabeledContent("Seed") { Text(String(r.seed)).textSelection(.enabled).monospacedDigit() }
                LabeledContent("Steps", value: "\(r.steps)")
                LabeledContent("Guidance", value: r.guidance.formatted(.number.precision(.fractionLength(1))))
                if store.model(id: record.modelID)?.kind != .mlx {
                    LabeledContent("Scheduler", value: r.scheduler.rawValue)
                }
                if let image { LabeledContent("Size", value: "\(image.width) × \(image.height)") }
                if let up = record.upscale {
                    LabeledContent("Upscaled", value: "\(up.scale)× with \(up.model), \(up.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                        .help("From \(up.source). The other settings are the original picture's.")
                }
                if let loras = r.loras, !loras.isEmpty {
                    LabeledContent("LoRA") {
                        VStack(alignment: .trailing) {
                            ForEach(loras) { Text("\($0.name) × \($0.scale.formatted(.number.precision(.fractionLength(2))))") }
                        }
                    }
                }
                if r.isImageToImage {
                    LabeledContent("Image-to-image", value: "change \((r.change ?? 0.6).formatted(.number.precision(.fractionLength(2))))")
                }
                if let ratio = r.stepCacheRatio {
                    LabeledContent("Skipped steps", value: "\(Int(ratio * 100))% near-identical steps reused")
                        .help("\"Skip near-identical steps\" was on. To make this exact picture again, keep it on in Settings.")
                }
                if let faster = r.fasterGPUMaths {
                    LabeledContent("GPU maths", value: faster ? "16-bit (faster)" : "32-bit")
                        .help("\"Faster GPU maths\" was \(faster ? "on" : "off"). To make this exact picture again, set it the same way in Settings.")
                }
                LabeledContent("Time", value: "\(record.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                LabeledContent("Made", value: record.date.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button("Use These Settings") { app.restore(record) }
                Button("Use as Start Image") {
                    app.useAsStartImage(url, for: store.model(id: app.selectedModelID))
                }
                UpscaleMenu(records: [record]) { Text("Upscale") }
                Button("Copy Image") {
                    guard let image else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                }
                .keyboardShortcut("c", modifiers: .command)
                Button("Copy Prompt") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(r.prompt, forType: .string)
                }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Move to Trash…", role: .destructive) { confirmTrash = true }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .formStyle(.grouped)
    }
}
