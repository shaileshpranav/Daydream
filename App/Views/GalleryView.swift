import SwiftUI

struct GalleryView: View {
    @Environment(AppState.self) private var app
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var store
    @Environment(Upscaler.self) private var upscaler
    @State private var records: [GenerationRecord] = []
    /// The image open in the full-size viewer, as an index into `records`.
    @State private var viewing: Int?
    @State private var search = ""

    /// Multi-select: while `selecting`, a click adds or removes a picture instead of opening it.
    /// ⌘-click and ⇧-click start selecting too.
    @State private var selecting = false
    @State private var selection: Set<String> = []
    /// Where a ⇧-click range starts: the last picture clicked.
    @State private var anchor: String?
    @State private var confirmTrash = false
    @State private var trashError: String?

    private let columns = [GridItem(.adaptive(minimum: 180), spacing: 12)]

    var body: some View {
        Group {
            if viewing != nil {
                ImageViewer(records: shown, index: $viewing, onTrash: trashFromViewer)
            } else {
                grid
            }
        }
        .navigationTitle("My Pictures")
        .alert("Couldn't move to the Trash", isPresented: Binding(
            get: { trashError != nil }, set: { if !$0 { trashError = nil } }
        )) {
            Button("OK") { trashError = nil }
        } message: {
            Text(trashError ?? "")
        }
        .task {
            records = await ImageSaver.loadRecords()
            #if DEBUG
            // -snapshots shows select mode with two pictures selected.
            if UserDefaults.standard.string(forKey: "snapshots") != nil {
                selecting = true
                selection = Set(records.prefix(2).map(\.fileName))
            }
            #endif
        }
        .onChange(of: generator.lastRecord) {
            // A new image: add it at the top rather than rescanning the whole folder,
            // keeping the viewer on the image it's showing.
            if let record = generator.lastRecord, !records.contains(record) {
                records.insert(record, at: 0)
                if let viewing, shown.contains(record) { self.viewing = viewing + 1 }
            }
        }
        .onChange(of: upscaler.lastRecord) {
            if let record = upscaler.lastRecord, !records.contains(record) {
                records.insert(record, at: 0)
                if let viewing, shown.contains(record) { self.viewing = viewing + 1 }
            }
        }
    }

    private func trashFromViewer(_ record: GenerationRecord) {
        guard let index = shown.firstIndex(of: record), trash([record]) else { return }
        viewing = shown.isEmpty ? nil : min(index, shown.count - 1)
    }

    /// Moves pictures to the Trash. Ones that couldn't be moved stay listed (and selected),
    /// and an alert says why. Returns whether every one was moved.
    @discardableResult
    private func trash(_ pictures: [GenerationRecord]) -> Bool {
        var moved: Set<String> = []
        var errors: [String] = []
        for record in pictures {
            do {
                try ImageSaver.delete(record)
                moved.insert(record.fileName)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        records.removeAll { moved.contains($0.fileName) }
        selection.subtract(moved)
        if selection.isEmpty { selecting = false }
        if !errors.isEmpty {
            trashError = errors.count == 1 ? errors[0]
                : "\(errors.count) pictures couldn't be moved. The first: \(errors[0])"
        }
        return errors.isEmpty
    }

    /// The pictures matching the search, newest first.
    private var shown: [GenerationRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.request.prompt.localizedCaseInsensitiveContains(query) || $0.modelName.localizedCaseInsensitiveContains(query)
        }
    }

    /// The selected pictures, in gallery order.
    private var selected: [GenerationRecord] {
        records.filter { selection.contains($0.fileName) }
    }

    private func fileURL(_ record: GenerationRecord) -> URL {
        ImageSaver.folder.appending(path: record.fileName)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HeaderBar {
                if selecting {
                    selectionBar
                } else {
                    Text("My Pictures").font(.headline)
                    Text("\(records.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    UpscaleStatus()
                    SearchField(prompt: "Search prompts and models", text: $search)
                    Button("Select") { selecting = true }
                        .controlSize(.small)
                        .disabled(records.isEmpty)
                        .help("Select several pictures (or ⌘-click, ⇧-click)")
                    Button("Open Folder", systemImage: "folder") {
                        NSWorkspace.shared.open(ImageSaver.folder)
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Open the pictures folder in Finder")
                }
            }
            gridContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Move \(selection.count) picture\(selection.count == 1 ? "" : "s") to the Trash?",
                            isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { trash(selected) }
        }
    }

    /// The header while selecting: the count and what can be done with the selection.
    @ViewBuilder
    private var selectionBar: some View {
        let urls = selected.map(fileURL)
        Text(selection.isEmpty ? "Select pictures" : "\(selection.count) selected").font(.headline)
        Spacer()
        UpscaleStatus()
        Button(selection.count == shown.count ? "Deselect All" : "Select All") {
            if selection.count == shown.count {
                selection.removeAll()
            } else {
                selection = Set(shown.map(\.fileName))
            }
        }
        .keyboardShortcut("a", modifiers: .command)
        .controlSize(.small)
        Group {
            Button("Copy", systemImage: "doc.on.doc") { copy(urls) }
                .help("Copy the selected pictures")
            ShareLink(items: urls) { Label("Share", systemImage: "square.and.arrow.up") }
                .help("Share the selected pictures")
            UpscaleMenu(records: selected) {
                Label("Upscale", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .help("Upscale the selected pictures 2× or 4×")
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                .help("Show the selected pictures in Finder")
            Button("Move to Trash", systemImage: "trash") { confirmTrash = true }
                .help("Move the selected pictures to the Trash")
        }
        .buttonStyle(IconButtonStyle())
        .disabled(selection.isEmpty)
        Button("Done") {
            selecting = false
            selection.removeAll()
        }
        .keyboardShortcut(.cancelAction)
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    /// Each picture goes on the pasteboard as PNG data and as its file, so it pastes as an
    /// image in Messages, Slack or an editor, and as files in Finder.
    private func copy(_ urls: [URL]) {
        let items = urls.map { url in
            let item = NSPasteboardItem()
            if let data = try? Data(contentsOf: url) { item.setData(data, forType: .png) }
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
    }

    /// A click opens the picture, or while selecting (or with ⌘ or ⇧) changes the selection.
    private func click(_ record: GenerationRecord, at index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor, let start = shown.firstIndex(where: { $0.fileName == anchor }) {
            selecting = true
            let range = min(start, index)...max(start, index)
            selection.formUnion(shown[range].map(\.fileName))
        } else if flags.contains(.command) || selecting {
            selecting = true
            if selection.remove(record.fileName) == nil { selection.insert(record.fileName) }
            anchor = record.fileName
        } else {
            anchor = record.fileName
            viewing = index
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView {
                    Label("No pictures yet", systemImage: "photo.on.rectangle")
                } description: {
                    Text("Every picture you create is saved here automatically.")
                } actions: {
                    Button("Create a Picture") { app.section = .generate }
                        .buttonStyle(.borderedProminent)
                }
            } else if shown.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, record in
                            GalleryCell(record: record, selecting: selecting,
                                        isSelected: selection.contains(record.fileName))
                                .onTapGesture { click(record, at: index) }
                                .contextMenu { menu(for: record, at: index) }
                        }
                    }
                    .padding()
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for record: GenerationRecord, at index: Int) -> some View {
        if selection.contains(record.fileName), selection.count > 1 {
            // Right-clicking one of several selected pictures acts on all of them.
            let urls = selected.map(fileURL)
            Button("Copy \(urls.count) Pictures") { copy(urls) }
            Button("Show \(urls.count) Pictures in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            UpscaleMenu(records: selected) { Text("Upscale \(urls.count) Pictures") }
            Divider()
            Button("Move \(urls.count) Pictures to Trash", role: .destructive) { confirmTrash = true }
        } else {
            Button("View") { viewing = index }
            Button(selection.contains(record.fileName) ? "Deselect" : "Select") {
                selecting = true
                if selection.remove(record.fileName) == nil { selection.insert(record.fileName) }
                anchor = record.fileName
            }
            Button("Reuse These Settings") { app.restore(record) }
            Button("Open in Edit") { app.openEditor(record) }
            Button("Use as Start Image") {
                app.useAsStartImage(fileURL(record), for: store.model(id: app.selectedModelID))
            }
            UpscaleMenu(records: [record]) { Text("Upscale") }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL(record)])
            }
            Divider()
            Button("Move to Trash", role: .destructive) { trash([record]) }
        }
    }
}

private struct GalleryCell: View {
    let record: GenerationRecord
    var selecting = false
    var isSelected = false
    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: isSelected ? 3 : 0)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.35))
                        .shadow(radius: 2)
                        .padding(8)
                }
            }
            Text(record.request.prompt)
                .font(.caption)
                .lineLimit(2)
            Text("\(record.modelName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .help(selecting ? "Click to select or deselect" : "Click to view full size; ⌘-click to select; right-click for more")
        .task(id: record.fileName) {
            let record = record
            thumbnail = await Task.detached { ImageSaver.thumbnail(for: record) }.value
        }
    }
}
