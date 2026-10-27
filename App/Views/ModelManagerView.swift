import SwiftUI
import UniformTypeIdentifiers

struct ModelManagerView: View {
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    @State private var importing = false
    @State private var pendingImport: URL?

    private let ramGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

    var body: some View {
        List {
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Section("Installed") {
                if store.installed.isEmpty {
                    Text("Nothing installed yet. Download a model below or import one you converted.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.installed) { model in
                    InstalledRow(model: model)
                }
            }

            Section("Available to download") {
                ForEach(ModelCatalog.entries.filter { !store.isInstalled($0) }) { entry in
                    CatalogRow(entry: entry, ramGB: ramGB)
                }
            }
        }
        .navigationTitle("Models")
        .toolbar {
            Button("Import Converted Model…", systemImage: "square.and.arrow.down") { importing = true }
            Button("Reveal Models Folder", systemImage: "folder") { NSWorkspace.shared.open(store.root) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { pendingImport = url }
        }
        .sheet(item: $pendingImport) { url in
            ImportSheet(source: url)
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct InstalledRow: View {
    @Environment(ModelStore.self) private var store
    @Environment(Generator.self) private var generator
    let model: InstalledModel
    @State private var size: Int64?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.name).font(.headline)
                    if generator.loadedModelID == model.id {
                        Text("loaded").font(.caption).padding(.horizontal, 6).background(.green.opacity(0.2), in: Capsule())
                    }
                }
                Text("\(model.kind.label) · \(model.resolution) px · \(size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let loras = model.loras, !loras.isEmpty {
                    Text("LoRA: " + loras.map(\.label).joined(separator: ", "))
                        .font(.caption)
                }
                if !model.kind.isRunnable {
                    Text("No backend for this kind yet.").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Picker("Compute", selection: Binding(
                get: { model.computeUnits },
                set: { store.setComputeUnits($0, for: model) }
            )) {
                ForEach(ComputeUnitsChoice.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 180)
            .disabled(generator.isBusy)
            Button("Delete", role: .destructive) {
                if generator.loadedModelID == model.id { generator.unloadModel() }
                store.delete(model)
            }
            .disabled(generator.isBusy)
        }
        .padding(.vertical, 4)
        .task(id: model.id) {
            let folder = model.folder!
            size = await Task.detached { ModelStore.directorySize(folder) }.value
        }
    }
}

private struct CatalogRow: View {
    @Environment(ModelStore.self) private var store
    let entry: CatalogEntry
    let ramGB: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.headline)
                Text("\(entry.kind.label) · \(entry.resolution) px · ~\(entry.approxGB, specifier: "%.1f") GB · \(entry.repo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let notes = entry.notes {
                    Text(notes).font(.caption)
                }
                if let license = entry.license {
                    Text(license).font(.caption).foregroundStyle(.orange)
                }
                if entry.approxGB > ramGB * 0.7 {
                    Label("Larger than ~70% of this Mac's \(Int(ramGB.rounded())) GB RAM", systemImage: "memorychip")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if let download = store.downloads[entry.id] {
                ProgressView(value: download.fraction).frame(width: 140)
                Text("\(Int(download.fraction * 100))%").monospacedDigit().frame(width: 40)
                Button("Cancel") { store.cancelDownload(entry) }
            } else if entry.kind.isRunnable {
                Button("Download") { store.download(entry) }
            } else {
                Text("Not supported yet").foregroundStyle(.secondary)
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
