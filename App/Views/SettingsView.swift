import SwiftUI

/// The pages of the Settings section, shown as tabs along its header bar.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case speed = "Speed & Memory"
    case addDetail = "Add Detail"
    case storage = "Storage"
    case runtime = "MLX Runtime"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .speed: "gauge.with.dots.needle.67percent"
        case .addDetail: "sparkles"
        case .storage: "internaldrive"
        case .runtime: "cpu"
        case .about: "info.circle"
        }
    }
}

/// The Settings section: every preference in the app, grouped into tabs.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Settings").font(.headline)
                Spacer()
                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { SubTab(tab: $0, selection: $tab) }
                }
                Spacer()
            }
            Group {
                switch tab {
                case .general: GeneralSettings()
                case .speed: SpeedSettings()
                case .addDetail: AddDetailSettings()
                case .storage: StorageSettings()
                case .runtime: RuntimeSettings()
                case .about: AboutSettings()
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Settings")
    }
}

/// A tab in the Settings header: icon and title, highlighted when selected. It reads the
/// selection itself: a ButtonStyle given `isSelected` didn't redraw when only that changed.
private struct SubTab: View {
    let tab: SettingsTab
    @Binding var selection: SettingsTab
    @State private var hovering = false

    var body: some View {
        let isSelected = selection == tab
        Button { selection = tab } label: {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.accent : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Theme.accent.opacity(0.18) : hovering ? Theme.raised : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
}

/// A toggle with an explanation under its title (a grouped Form shows the second Text as a
/// subtitle in the same row).
private func toggle(_ title: String, _ detail: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
        Text(title)
        Text(detail)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(GenerationQueue.self) private var queue
    @AppStorage("preloadModels") private var preloadModels = true
    @AppStorage("randomSeed") private var randomSeed = true
    @AppStorage("showGalleryPanel") private var showGallery = true
    @AppStorage("showImageInfo") private var showInfo = false
    @AppStorage("showAdvancedInstall") private var showAdvancedInstall = false
    @AppStorage(QueueNotifier.enabledKey) private var notify = true
    @AppStorage(GenerationQueue.dockBadgeKey) private var dockBadge = true
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark
    @State private var confirmingReset = false

    var body: some View {
        Form {
            Section("Appearance") {
                Picker(selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Look")
                    Text("Also in the View menu. Match System follows macOS's light or dark setting.")
                }
                .pickerStyle(.segmented)
            }

            Section("Models") {
                toggle("Get the model ready as soon as I pick it",
                       "Pictures then start right away. Turn off to keep your Mac's memory free until you create a picture.",
                       isOn: $preloadModels)
                toggle("Show advanced ways to add models",
                       "Adds installing from a Hugging Face repo and importing your own Core ML conversion to the Models page.",
                       isOn: $showAdvancedInstall)
            }

            Section("Create") {
                toggle("Use a new random seed for each picture",
                       "Turn off to keep the seed, so the same prompt and settings make the same picture again.",
                       isOn: $randomSeed)
                toggle("Show recent pictures beside the picture", "The same as the Gallery button on the Create screen.",
                       isOn: $showGallery)
                toggle("Show the picture's settings over it", "The same as the Info button on the Create screen (⌘I).",
                       isOn: $showInfo)
            }

            Section("When pictures are ready") {
                toggle("Notify me when a batch finishes while I'm in another app",
                       "For batches of two or more pictures. macOS asks for permission the first time.",
                       isOn: $notify)
                Toggle("Show how many pictures are left on the Dock icon", isOn: $dockBadge)
                    .onChange(of: dockBadge) { queue.updateDockBadge() }
            }

            Section {
                LabeledContent {
                    Button("Reset…") { confirmingReset = true }
                } label: {
                    Text("Reset all settings")
                    Text("Puts every setting on these pages back to how it started. Your pictures, models and LoRAs aren't touched.")
                }
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { SettingsDefaults.resetAll() }
        } message: {
            Text("Your pictures, models and LoRAs stay as they are.")
        }
    }
}

/// Every setting the Settings pages show, and their defaults.
@MainActor
enum SettingsDefaults {
    /// Defaults for settings code reads directly (not only through @AppStorage), registered at launch.
    static let registered: [String: Any] = [
        StableDiffusionBackend.lowPrecisionKey: true,
        MLXBackend.stepCacheKey: true,
        QueueNotifier.enabledKey: true,
        GenerationQueue.dockBadgeKey: true,
        MLXPromptRewriter.idleKey: 3,
        Generator.idleUnloadKey: 0,
        GenerationQueue.previewEveryKey: 5,
        GenerationQueue.lastPreviewEveryKey: 5,
    ]

    /// The rest: @AppStorage settings whose defaults live in the views.
    private static let viewKeys = [
        "preloadModels", "randomSeed", "showGalleryPanel", "showImageInfo", "showAdvancedInstall", AppearanceChoice.key,
        PromptEnhancer.engineKey, PromptEnhancer.modelKey, Ollama.urlKey, Ollama.modelKey,
    ]

    static func resetAll() {
        for key in Array(registered.keys) + viewKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

// MARK: - Speed & Memory

private struct SpeedSettings: View {
    @Environment(Generator.self) private var generator
    @AppStorage(GenerationQueue.previewEveryKey) private var previewEvery = 5
    @AppStorage(GenerationQueue.lastPreviewEveryKey) private var lastPreviewEvery = 5
    @AppStorage(StableDiffusionBackend.lowPrecisionKey) private var lowPrecisionGPU = true
    @AppStorage(MLXBackend.stepCacheKey) private var stepCache = true
    @AppStorage(Generator.idleUnloadKey) private var idleMinutes = 0
    @AppStorage(MLXPromptRewriter.idleKey) private var promptIdleMinutes = 3

    var body: some View {
        Form {
            Section("Speed") {
                toggle("Faster GPU maths for Core ML models",
                       "Uses 16-bit accumulation for Core ML models running on the GPU, like SDXL. Measured on SDXL here: 13% faster (7.7 vs 8.7 s per step) with no visible difference (PSNR 35 dB, only fine-texture changes). The Neural Engine and MLX models aren't affected. Takes effect on the next picture (the model reloads).",
                       isOn: $lowPrecisionGPU)

                toggle("Skip near-identical steps on long MLX models",
                       "MOSS-Image and Qwen-Image 2.1 (base) run 40–50 steps. This reuses the model's output on the quarter of steps that change least, so the model runs about a quarter fewer times per picture. The picture differs slightly from one made without it. Models with fewer than 10 steps aren't affected.",
                       isOn: $stepCache)

                Picker(selection: $previewEvery) {
                    Text("Off").tag(0)
                    ForEach([2, 5, 10], id: \.self) { Text("Every \($0) steps").tag($0) }
                } label: {
                    Text("Show the picture while it's being made")
                    Text("Each preview decodes the image with the VAE, which costs a little time. MLX models take few, slow steps, so they preview about three times per picture (never less often than this setting) and show the model's current guess at the finished picture rather than the noisy in-between state. The eye button above the picture in Create turns previews off and on.")
                }
                .onChange(of: previewEvery) { if previewEvery > 0 { lastPreviewEvery = previewEvery } }
            }

            Section("Memory") {
                LabeledContent("This Mac", value: "\(Int(MemoryEstimate.ramGB.rounded())) GB of memory")
                LabeledContent("Picture model in memory") {
                    HStack {
                        Text(generator.loadedModelID ?? "None").foregroundStyle(.secondary)
                        Button("Free") { generator.unloadModel() }
                            .disabled(generator.loadedModelID == nil || generator.isBusy)
                    }
                }

                Picker(selection: $idleMinutes) {
                    Text("Never").tag(0)
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes unused").tag($0) }
                } label: {
                    Text("Free the picture model after")
                    Text("Gives the model's memory back to other apps when you stop making pictures. It loads again when you next create a picture or open Create, which takes 5–30 s.")
                }
                .onChange(of: idleMinutes) { generator.restartIdleTimer() }

                Picker(selection: $promptIdleMinutes) {
                    ForEach([1, 3, 5, 10, 30], id: \.self) { Text("\($0) minute\($0 == 1 ? "" : "s") unused").tag($0) }
                } label: {
                    Text("Free the Add Detail model after")
                    Text("MLX language models use about 2–3 GB while loaded. Ollama is asked to keep its model for the same time. Apple Intelligence's memory is managed by macOS.")
                }

                AddDetailMemoryRow()

                LabeledContent {
                    Button("Free All Memory") {
                        generator.unloadModel()
                        Task { await PromptMemory.shared.unload() }
                    }
                    .disabled(generator.isBusy)
                } label: {
                    Text("Free both models now")
                    Text("For example before opening a large app.")
                }
            }
        }
    }
}

// MARK: - Add Detail

private struct AddDetailSettings: View {
    var body: some View {
        Form {
            Section {
                caption("Add Detail (⌘E in Create) rewrites a short prompt into a longer, more descriptive one before you make the picture. Pick which language model does the rewriting.")
            }
            PromptEnhancerSettings()
            Section("Memory") {
                AddDetailMemoryRow()
            }
        }
    }
}

/// The Add Detail model in memory, if any, with a button to free it.
private struct AddDetailMemoryRow: View {
    private var memory: PromptMemory { .shared }

    var body: some View {
        LabeledContent {
            HStack {
                Text(memory.loadedName ?? "None").foregroundStyle(.secondary)
                Button("Unload") { Task { await memory.unload() } }
                    .disabled(memory.loadedName == nil || memory.isUnloading)
            }
        } label: {
            Text("Add Detail model in memory")
            Text("Unloading frees its memory now; it loads again the next time you press Add Detail.")
        }
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    @Environment(ModelStore.self) private var store

    /// Sizes by folder path, filled in after the page appears (big folders take a moment).
    @State private var sizes: [String: Int64] = [:]
    @State private var pictureCount: Int?

    private var loras: URL { ModelStore.lorasFolder }

    var body: some View {
        Form {
            Section("Your pictures") {
                FolderRow(title: "Pictures", icon: "photo.on.rectangle", folder: ImageSaver.folder,
                          detail: pictureCount.map { "\($0) picture\($0 == 1 ? "" : "s")" },
                          size: sizes[ImageSaver.folder.path])
                caption("Each picture is a PNG with its settings saved inside it and in a .json file next to it.")
                FolderRow(title: "Start pictures", icon: "photo.badge.arrow.down", folder: StartImages.folder,
                          detail: "Copies of pictures you started from",
                          size: sizes[StartImages.folder.path])
            }

            Section("Models") {
                FolderRow(title: "Picture models", icon: "shippingbox", folder: store.root,
                          detail: "\(store.installed.count) installed",
                          size: sizes[store.root.path].map { $0 - (sizes[loras.path] ?? 0) })
                FolderRow(title: "LoRAs", icon: "slider.horizontal.3", folder: loras,
                          detail: "Drop .safetensors files here", size: sizes[loras.path])
                FolderRow(title: "Add Detail models", icon: "sparkles", folder: PromptModel.root,
                          detail: "MLX language models", size: sizes[PromptModel.root.path])
                FolderRow(title: "MLX runtime", icon: "cpu", folder: MLXRuntime.root,
                          detail: "Python, MLX and mflux", size: sizes[MLXRuntime.root.path])
                caption("Remove models on the Models page, and the MLX runtime under MLX Runtime.")
            }

            Section {
                LabeledContent("Free space on this disk") {
                    Text(store.freeDiskBytes.map(Self.format) ?? "Unknown")
                }
            }
        }
        .task { await measure() }
    }

    private func measure() async {
        let folders = [ImageSaver.folder, StartImages.folder, store.root, loras, PromptModel.root, MLXRuntime.root]
        for folder in folders {
            let size = await Task.detached { ModelStore.directorySize(folder) }.value
            sizes[folder.path] = size
        }
        let pictures = ImageSaver.folder
        pictureCount = await Task.detached {
            ((try? FileManager.default.contentsOfDirectory(atPath: pictures.path)) ?? [])
                .count { $0.lowercased().hasSuffix(".png") }
        }.value
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A folder the app keeps files in: what it's for, where it is, its size, and a Finder button.
private struct FolderRow: View {
    let title: String
    let icon: String
    let folder: URL
    var detail: String?
    var size: Int64?

    private var exists: Bool { FileManager.default.fileExists(atPath: folder.path) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                    if let detail { Text("· \(detail)").foregroundStyle(.secondary) }
                }
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            if !exists {
                Text("Not created yet").foregroundStyle(.secondary)
            } else if let size {
                Text(StorageSettings.format(size)).monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(folder) }
                .labelStyle(.iconOnly)
                .help("Show in Finder")
                .disabled(!exists)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - MLX Runtime

private struct RuntimeSettings: View {
    @Environment(MLXRuntime.self) private var runtime
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var store
    @State private var confirmingRemove = false
    @State private var removeError: String?

    private var hasEnvironment: Bool { FileManager.default.isExecutableFile(atPath: MLXRuntime.python.path) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MLX runtime").font(.headline)
                        caption("A private Python environment that runs MLX picture models and MLX Add Detail models on the GPU. Core ML models don't need it.")
                    }
                    Spacer()
                    statusBadge
                }
                switch runtime.status {
                case .installing(let line):
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(line).font(.caption.monospaced()).lineLimit(1).foregroundStyle(.secondary)
                    }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                default:
                    EmptyView()
                }
                HStack {
                    switch runtime.status {
                    case .notInstalled:
                        Button(hasEnvironment ? "Update" : "Install") { runtime.install() }
                            .buttonStyle(.borderedProminent)
                    case .failed:
                        Button("Retry") { runtime.install() }
                            .buttonStyle(.borderedProminent)
                    case .installed:
                        Button("Reinstall Packages") { runtime.reinstall() }
                            .help("Installs the pinned packages again, e.g. if the environment was changed by hand")
                    case .installing:
                        EmptyView()
                    }
                    Spacer()
                    Button("Show Log") { NSWorkspace.shared.open(MLXRuntime.logURL) }
                        .disabled(!FileManager.default.fileExists(atPath: MLXRuntime.logURL.path))
                    Button("Show in Finder") { NSWorkspace.shared.open(MLXRuntime.root) }
                        .disabled(!FileManager.default.fileExists(atPath: MLXRuntime.root.path))
                }
            }

            Section("Details") {
                LabeledContent("Packages", value: MLXRuntime.packages.joined(separator: ", "))
                LabeledContent("Python") {
                    Text(hasEnvironment ? (MLXRuntime.python.path as NSString).abbreviatingWithTildeInPath : "Python 3.11+ from Homebrew")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Picture models it runs") {
                    Text(MLXFamilies.all.map(\.label).joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Installed MLX models", value: "\(store.installed.count { $0.kind == .mlx })")
            }

            Section {
                LabeledContent {
                    Button("Move to Trash…", role: .destructive) { confirmingRemove = true }
                        .disabled(!FileManager.default.fileExists(atPath: MLXRuntime.root.path)
                                  || generator.isBusy || runtime.status != .installed && runtime.status != .notInstalled)
                } label: {
                    Text("Remove the MLX runtime")
                    Text("Moves it to the Trash to free its disk space. MLX models stay installed but won't run until you install it again.")
                }
                if let removeError {
                    Text(removeError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog("Move the MLX runtime to the Trash?", isPresented: $confirmingRemove) {
            Button("Move to Trash", role: .destructive, action: remove)
        } message: {
            Text("MLX models won't run until you install it again.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch runtime.status {
        case .installed: Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .installing: Label("Installing", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .notInstalled: Label("Not installed", systemImage: "circle.dashed").foregroundStyle(.secondary)
        case .failed: Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func remove() {
        // Stop the workers first so nothing runs from the environment being moved.
        if store.model(id: generator.loadedModelID)?.kind == .mlx { generator.unloadModel() }
        MLXPromptRewriter.shared.unload()
        do {
            try runtime.moveToTrash()
            removeError = nil
        } catch {
            removeError = error.localizedDescription
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0)
        return size > 0 ? String(cString: bytes) : "Unknown"
    }

    private let shortcuts: [(String, String)] = [
        ("Create, My Pictures, Queue, Models", "⌥⌘1 – ⌥⌘4"),
        ("Settings", "⌘,"),
        ("Create the picture", "⌘↩"),
        ("Stop the picture being made", "Esc"),
        ("Add Detail", "⌘E"),
        ("Show the picture's settings", "⌘I"),
        ("Fit / actual size", "⌘0 / ⌘1"),
        ("Zoom out / in", "⌘− / ⌘+"),
        ("Previous / next picture in the viewer", "← / →"),
        ("Copy the picture in the viewer", "⌘C"),
        ("Move the picture to the Trash in the viewer", "⌘⌫"),
        ("Back to My Pictures from the viewer", "Esc"),
    ]

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("CoreMLImageGen").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        caption("Makes pictures on this Mac with Core ML and MLX.")
                    }
                }
                .padding(.vertical, 4)
            }

            Section("This Mac") {
                LabeledContent("Chip", value: chip)
                LabeledContent("Memory", value: "\(Int(MemoryEstimate.ramGB.rounded())) GB")
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
            }

            Section("Keyboard shortcuts") {
                ForEach(shortcuts, id: \.0) { name, keys in
                    LabeledContent(name) {
                        Text(keys).font(.body.monospaced())
                    }
                }
            }
        }
    }
}
