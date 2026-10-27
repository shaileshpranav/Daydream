import SwiftUI

@main
struct CoreMLImageGenApp: App {
    @State private var app = AppState()
    @State private var store = ModelStore()
    @State private var generator: Generator
    @State private var queue: GenerationQueue
    @State private var mlxRuntime = MLXRuntime()
    @State private var loraLibrary = LoRALibrary()

    init() {
        // Defaults for settings the backends read directly (not just through @AppStorage).
        UserDefaults.standard.register(defaults: [StableDiffusionBackend.lowPrecisionKey: true])
        let generator = Generator()
        _generator = State(initialValue: generator)
        _queue = State(initialValue: GenerationQueue(generator: generator))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(store)
                .environment(generator)
                .environment(queue)
                .environment(mlxRuntime)
                .environment(loraLibrary)
                .frame(minWidth: 900, minHeight: 620)
                #if DEBUG
                .task { SmokeTest.runIfRequested(store: store, generator: generator, queue: queue) }
                #endif
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environment(generator)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case generate = "Create"
    case gallery = "My Pictures"
    case models = "Models"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .generate: "wand.and.stars"
        case .gallery: "photo.on.rectangle"
        case .models: "shippingbox"
        }
    }
}

/// UI state shared between sections, e.g. so the gallery can send settings back to Generate.
@MainActor
@Observable
final class AppState {
    var section: AppSection = .generate
    var request = GenerationRequest(prompt: "a cozy reading nook by a rainy window, warm lamp light, film photo")
    var selectedModelID: String? = UserDefaults.standard.string(forKey: "selectedModelID") {
        didSet { UserDefaults.standard.set(selectedModelID, forKey: "selectedModelID") }
    }

    /// Set while restoring from the gallery so switching model doesn't overwrite the
    /// restored steps and guidance with the model's defaults.
    var isRestoring = false

    /// The launch request has generic SD settings; Create swaps in the model's recommended
    /// ones the first time it appears.
    var appliedLaunchDefaults = false

    /// A finished image the user clicked in the queue, shown instead of the latest one.
    var viewedRecord: GenerationRecord?

    /// True while a debug smoke test drives the app, so it doesn't preload models itself.
    var automationRunning = ["smokeTest", "queueTest", "img2imgTest", "loraTest", "enhanceTest", "preloadTest",
                             "precisionTest", "managerTest", "previewTest"]
        .contains { UserDefaults.standard.object(forKey: $0) != nil }

    var startImageError: String?

    /// Makes `url` the image-to-image start image. For MLX models (any size) the aspect
    /// is switched to the one closest to the image so it isn't squashed.
    func useAsStartImage(_ url: URL, for model: InstalledModel?) {
        do {
            let path = try StartImages.importImage(url)
            request.startImage = path
            if request.change == nil { request.change = 0.6 }
            if model?.kind.hasFixedSize == false, let aspect = StartImages.closestAspect(to: path) {
                request.aspect = aspect
            }
            startImageError = nil
            section = .generate
        } catch {
            startImageError = error.localizedDescription
        }
    }

    func restore(_ record: GenerationRecord) {
        isRestoring = selectedModelID != record.modelID
        request = record.request
        selectedModelID = record.modelID
        section = .generate
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            List(AppSection.allCases, selection: $app.section) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            switch app.section {
            case .generate: GenerateView()
            case .gallery: GalleryView()
            case .models: ModelManagerView()
            }
        }
    }
}
