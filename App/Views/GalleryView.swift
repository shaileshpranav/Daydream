import SwiftUI

struct GalleryView: View {
    @Environment(AppState.self) private var app
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var store
    @State private var records: [GenerationRecord] = []
    /// The image open in the full-size viewer, as an index into `records`.
    @State private var viewing: Int?
    @State private var search = ""

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
        .onAppear(perform: reload)
        .onChange(of: generator.lastRecord) {
            // A new image: add it at the top rather than rescanning the whole folder,
            // keeping the viewer on the image it's showing.
            if let record = generator.lastRecord, !records.contains(record) {
                records.insert(record, at: 0)
                if let viewing, shown.contains(record) { self.viewing = viewing + 1 }
            }
        }
    }

    private func trashFromViewer(_ record: GenerationRecord) {
        guard let index = shown.firstIndex(of: record) else { return }
        ImageSaver.delete(record)
        records.removeAll { $0 == record }
        viewing = shown.isEmpty ? nil : min(index, shown.count - 1)
    }

    /// The pictures matching the search, newest first.
    private var shown: [GenerationRecord] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return records }
        return records.filter {
            $0.request.prompt.localizedCaseInsensitiveContains(query) || $0.modelName.localizedCaseInsensitiveContains(query)
        }
    }

    @ViewBuilder
    private var grid: some View {
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
                            GalleryCell(record: record)
                                .onTapGesture { viewing = index }
                                .contextMenu {
                                    Button("View") { viewing = index }
                                    Button("Reuse These Settings") { app.restore(record) }
                                    Button("Edit This Picture") {
                                        app.useAsStartImage(ImageSaver.folder.appending(path: record.fileName),
                                                            for: store.model(id: app.selectedModelID))
                                    }
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([ImageSaver.folder.appending(path: record.fileName)])
                                    }
                                    Divider()
                                    Button("Move to Trash", role: .destructive) {
                                        ImageSaver.delete(record)
                                        reload()
                                    }
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .searchable(text: $search, prompt: "Search descriptions")
        .toolbar {
            Button("Open Folder", systemImage: "folder") {
                NSWorkspace.shared.open(ImageSaver.folder)
            }
        }
    }

    private func reload() {
        records = ImageSaver.loadRecords()
    }
}

private struct GalleryCell: View {
    let record: GenerationRecord
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
            Text(record.request.prompt)
                .font(.caption)
                .lineLimit(2)
            Text("\(record.modelName) · \(record.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help("Click to view full size; right-click for more")
        .task(id: record.fileName) {
            let record = record
            thumbnail = await Task.detached { ImageSaver.thumbnail(for: record) }.value
        }
    }
}
