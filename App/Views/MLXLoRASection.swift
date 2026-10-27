import SwiftUI
import UniformTypeIdentifiers

/// LoRAs for MLX models. Unlike Core ML (fused at conversion), these load with the model,
/// so changing them only costs a reload of the weights, not a conversion.
/// Only LoRAs trained for the selected model's base can be added (see LoRAInspector).
struct MLXLoRASection: View {
    let model: InstalledModel
    @Binding var loras: [LoRARef]
    @State private var picking = false
    @State private var repo = ""
    @State private var checkingRepo = false
    @State private var message: String?
    @State private var library: [(url: URL, result: LoRAInspector.Result)] = []

    private var base: LoRABase? { model.loraBase }

    var body: some View {
        Section {
            ForEach($loras) { $lora in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(lora.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button {
                            loras.removeAll { $0.id == lora.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    HStack {
                        Slider(value: $lora.scale, in: 0...1.5, step: 0.05)
                        Text(lora.scale, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                            .frame(width: 36)
                    }
                }
                .help(lora.source)
            }

            if base == nil {
                Text("This model doesn't support LoRAs yet.").foregroundStyle(.secondary)
            } else {
                libraryMenu
                HStack {
                    TextField("Hugging Face repo", text: $repo, prompt: Text("user/lora-repo"))
                        .onSubmit(addRepo)
                    if checkingRepo {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add", action: addRepo).disabled(!repo.contains("/"))
                    }
                }
                Button("Add .safetensors File…") { picking = true }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("LoRA")
        } footer: {
            Text("Only LoRAs trained for \(base?.label ?? "this model") can be added. Put files in Models/Loras to list them here. Changing LoRAs reloads the model on the next generate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            dropIncompatible()  // e.g. came back from a Core ML model to a different MLX one
            reloadLibrary()
        }
        .onChange(of: model.id) {
            message = nil
            dropIncompatible()
            reloadLibrary()
        }
        .fileDialogDefaultDirectory(ModelStore.lorasFolder)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls { addFile(url) }
            }
        }
    }

    // MARK: Loras folder

    private var libraryMenu: some View {
        let compatible = library.filter { $0.result == .known(base!) }
        let others = library.filter { $0.result != .known(base!) }
        return Menu("Add from Loras Folder (\(compatible.count))") {
            if compatible.isEmpty {
                Text("No \(base!.label) LoRAs in the Loras folder")
            }
            ForEach(compatible, id: \.url) { item in
                let added = loras.contains { $0.source == item.url.path }
                Button(added ? "\(libraryName(item.url)) ✓" : libraryName(item.url)) {
                    loras.append(LoRARef(source: item.url.path, base: base))
                }
                .disabled(added)
            }
            if !others.isEmpty {
                Divider()
                Section("Not for \(base!.label)") {
                    ForEach(others, id: \.url) { item in
                        Text("\(libraryName(item.url)) — \(describe(item.result))")
                    }
                }
            }
            Divider()
            Button("Rescan Folder") { reloadLibrary() }
            Button("Show Loras Folder in Finder") { NSWorkspace.shared.open(ModelStore.lorasFolder) }
        }
    }

    private func reloadLibrary() {
        library = ModelStore.libraryLoRAs().map { ($0, LoRAInspector.inspect(file: $0)) }
    }

    /// File name without extension, with its subfolder if it's in one ("flux2/Style").
    private func libraryName(_ url: URL) -> String {
        let root = ModelStore.lorasFolder.standardizedFileURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(root) { relative = String(relative.dropFirst(root.count)).trimmingCharacters(in: ["/"]) }
        return (relative as NSString).deletingPathExtension
    }

    private func describe(_ result: LoRAInspector.Result) -> String {
        switch result {
        case .known(let other): "for \(other.label)"
        case .unknown: "base model not recognized"
        }
    }

    // MARK: Adding

    private func addFile(_ url: URL) {
        guard let base, !loras.contains(where: { $0.source == url.path }) else { return }
        switch LoRAInspector.inspect(file: url) {
        case .known(base):
            loras.append(LoRARef(source: url.path, base: base))
            message = nil
        case .known(let other):
            message = "\(url.lastPathComponent) is a \(other.label) LoRA; \(model.name) needs a \(base.label) LoRA."
        case .unknown(let reason):
            message = "Can't tell which model \(url.lastPathComponent) is for (\(reason.lowercased())), so it can't be added."
        }
    }

    private func addRepo() {
        let source = repo.trimmingCharacters(in: .whitespaces)
        guard let base, source.contains("/"), !loras.contains(where: { $0.source == source }) else { return }
        checkingRepo = true
        message = nil
        Task {
            defer { checkingRepo = false }
            do {
                let (file, result) = try await LoRAInspector.inspect(repo: source)
                switch result {
                case .known(base):
                    loras.append(LoRARef(source: source, base: base))
                    repo = ""
                case .known(let other):
                    message = "\(source) (\(file)) is a \(other.label) LoRA; \(model.name) needs a \(base.label) LoRA."
                case .unknown(let reason):
                    message = "Can't tell which model \(source) is for (\(reason.lowercased())), so it can't be added."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// After switching models, LoRAs for another base would fail to load: drop them.
    private func dropIncompatible() {
        let kept = loras.filter { $0.base == base }
        let dropped = loras.count - kept.count
        if dropped > 0 {
            loras = kept
            message = "Removed \(dropped) LoRA\(dropped == 1 ? "" : "s") that \(dropped == 1 ? "isn't" : "aren't") for \(base?.label ?? model.name)."
        }
    }
}
