import SwiftUI

struct SettingsView: View {
    @Environment(Generator.self) private var generator
    @AppStorage("previewEvery") private var previewEvery = 5
    @AppStorage("preloadModels") private var preloadModels = true
    @AppStorage(StableDiffusionBackend.lowPrecisionKey) private var lowPrecisionGPU = true
    @AppStorage(MLXBackend.stepCacheKey) private var stepCache = true

    var body: some View {
        Form {
            Toggle("Get the model ready as soon as I pick it", isOn: $preloadModels)
            Text("Pictures then start right away. Turn off to keep your Mac's memory free until you create a picture.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Faster GPU maths for Core ML models (16-bit accumulation)", isOn: $lowPrecisionGPU)
            Text("Applies to Core ML models running on the GPU, like SDXL. Measured on SDXL here: 13% faster (7.7 vs 8.7 s per step) with no visible difference (PSNR 35 dB, only fine-texture changes). The Neural Engine and MLX models aren't affected. Takes effect on the next image (the model reloads).")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Skip near-identical steps on long MLX models", isOn: $stepCache)
            Text("MOSS-Image and Qwen-Image 2.1 (base) run 40–50 steps. This reuses the model's output on the quarter of steps that change least, so the model runs about a quarter fewer times per picture. The picture differs slightly from one made without it. Models with fewer than 10 steps aren't affected.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Show the picture while it's being made", selection: $previewEvery) {
                Text("Off").tag(0)
                ForEach([2, 5, 10], id: \.self) { Text("Every \($0) steps").tag($0) }
            }
            Text("Each preview decodes the image with the VAE, which costs a little time per preview. MLX models take few, slow steps, so they preview about three times per image (never less often than this setting) and show the model's current guess at the finished image rather than the noisy in-between state.")
                .font(.caption)
                .foregroundStyle(.secondary)

            PromptEnhancerSettings()

            LabeledContent("Pictures are saved to") {
                Button(ImageSaver.folder.path) { NSWorkspace.shared.open(ImageSaver.folder) }
                    .buttonStyle(.link)
            }

            LabeledContent("Model in memory") {
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
