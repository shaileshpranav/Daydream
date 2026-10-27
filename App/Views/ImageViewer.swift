import SwiftUI

/// Full-size view of a gallery image: zoomable image on the left, everything about how it
/// was made on the right. ← → move through the gallery, Esc closes.
struct ImageViewer: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store
    let records: [GenerationRecord]
    @Binding var index: Int?
    let onTrash: (GenerationRecord) -> Void

    /// nil = fit to the window; otherwise pixels per image pixel (1 = actual size).
    @State private var zoom: CGFloat?
    @State private var pinchStart: CGFloat?
    @State private var image: CGImage?
    @State private var confirmTrash = false
    @State private var areaSize: CGSize = .zero

    private var record: GenerationRecord? {
        guard let index, records.indices.contains(index) else { return nil }
        return records[index]
    }

    var body: some View {
        if let record {
            HSplitView {
                imageArea(record)
                    .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.85))
                InfoPanel(record: record, image: image, confirmTrash: $confirmTrash)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
            }
            .toolbar { toolbar(record) }
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
        GeometryReader { geo in
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                if let zoom {
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(zoom >= 2 ? .none : .high)
                            .frame(width: size.width * zoom, height: size.height * zoom)
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .gesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? (zoom ?? fitZoom)
                pinchStart = start
                zoom = min(max(start * value.magnification, 0.1), 8)
            }
            .onEnded { _ in pinchStart = nil })
        .onTapGesture(count: 2) { zoom = zoom == nil ? 1 : nil }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { areaSize = $0 }
        .help("Double-click to switch between fit and actual size; pinch to zoom")
    }

    /// The zoom "fit" corresponds to, so pinching starts from what's on screen.
    private var fitZoom: CGFloat {
        guard let image, image.width > 0, image.height > 0, areaSize.width > 0 else { return 1 }
        return min(areaSize.width / CGFloat(image.width), areaSize.height / CGFloat(image.height))
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ record: GenerationRecord) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back to Gallery", systemImage: "chevron.backward") { index = nil }
                .keyboardShortcut(.cancelAction)
        }
        ToolbarItemGroup {
            Button("Previous", systemImage: "arrow.left") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled((index ?? 0) <= 0)
            Text("\((index ?? 0) + 1) of \(records.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Next", systemImage: "arrow.right") { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled((index ?? 0) >= records.count - 1)
            Divider()
            Button("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { zoom = nil }
                .keyboardShortcut("0", modifiers: .command)
            Button("Actual Size", systemImage: "1.magnifyingglass") { zoom = 1 }
                .keyboardShortcut("1", modifiers: .command)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { zoom = min((zoom ?? 1) * 1.5, 8) }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { zoom = max((zoom ?? 1) / 1.5, 0.1) }
                .keyboardShortcut("-", modifiers: .command)
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
                LabeledContent("Time", value: "\(record.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                LabeledContent("Made", value: record.date.formatted(date: .abbreviated, time: .shortened))
            }
            Section {
                Button("Use These Settings") { app.restore(record) }
                Button("Use as Start Image") {
                    app.useAsStartImage(url, for: store.model(id: app.selectedModelID))
                }
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
