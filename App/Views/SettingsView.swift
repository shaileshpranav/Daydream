import SwiftUI

struct SettingsView: View {
    @Environment(Generator.self) private var generator
    @AppStorage("previewEvery") private var previewEvery = 5
    @AppStorage("preloadModels") private var preloadModels = true

    var body: some View {
        Form {
            Toggle("Load a model as soon as it's selected", isOn: $preloadModels)
            Text("Generate then starts at once instead of waiting for the model to load. Turn off to keep memory free until you generate.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Live preview", selection: $previewEvery) {
                Text("Off").tag(0)
                ForEach([2, 5, 10], id: \.self) { Text("Every \($0) steps").tag($0) }
            }
            Text("Each preview decodes the image with the VAE, which costs a little time per preview.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Images are saved to") {
                Button(ImageSaver.folder.path) { NSWorkspace.shared.open(ImageSaver.folder) }
                    .buttonStyle(.link)
            }

            LabeledContent("Resident model") {
                HStack {
                    Text(generator.loadedModelID ?? "none")
                    Button("Unload") { generator.unloadModel() }
                        .disabled(generator.loadedModelID == nil || generator.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}
