import SwiftUI
import UniformTypeIdentifiers

/// LoRAs for MLX models. Unlike Core ML (fused at conversion), these load with the model,
/// so changing them only costs a reload of the weights, not a conversion.
struct MLXLoRASection: View {
    @Binding var loras: [LoRARef]
    @State private var picking = false
    @State private var repo = ""
    @State private var library: [URL] = []

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
            Menu("Add from Loras Folder") {
                let available = library.filter { url in !loras.contains { $0.source == url.path } }
                if library.isEmpty {
                    Text("No .safetensors files in the Loras folder yet")
                } else if available.isEmpty {
                    Text("All LoRAs in the folder are added")
                }
                ForEach(available, id: \.self) { url in
                    Button(libraryName(url)) { loras.append(LoRARef(source: url.path)) }
                }
                Divider()
                Button("Rescan Folder") { reloadLibrary() }
                Button("Show Loras Folder in Finder") { NSWorkspace.shared.open(ModelStore.lorasFolder) }
            }
            HStack {
                TextField("Hugging Face repo", text: $repo, prompt: Text("user/lora-repo"))
                    .onSubmit(addRepo)
                Button("Add", action: addRepo)
                    .disabled(!repo.contains("/"))
            }
            Button("Add .safetensors File…") { picking = true }
        } header: {
            Text("LoRA")
        } footer: {
            Text("Put LoRA files in Models/Loras to list them here. Must match the model family (e.g. a FLUX.2 Klein 4B LoRA for FLUX.2 Klein 4B). Changing LoRAs reloads the model on the next generate.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear(perform: reloadLibrary)
        .fileDialogDefaultDirectory(ModelStore.lorasFolder)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [UTType(filenameExtension: "safetensors") ?? .data],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                for url in urls where !loras.contains(where: { $0.source == url.path }) {
                    loras.append(LoRARef(source: url.path))
                }
            }
        }
    }

    private func reloadLibrary() {
        library = ModelStore.libraryLoRAs()
    }

    /// File name without extension, with its subfolder if it's in one ("flux2/Style").
    private func libraryName(_ url: URL) -> String {
        let base = ModelStore.lorasFolder.standardizedFileURL.path
        var relative = url.standardizedFileURL.path
        if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)).trimmingCharacters(in: ["/"]) }
        return (relative as NSString).deletingPathExtension
    }

    private func addRepo() {
        let source = repo.trimmingCharacters(in: .whitespaces)
        guard source.contains("/"), !loras.contains(where: { $0.source == source }) else { return }
        loras.append(LoRARef(source: source))
        repo = ""
    }
}
