import SwiftUI

@main
struct CoreMLImageGenApp: App {
    @State private var app = AppState()
    @State private var store = ModelStore()
    @State private var generator = Generator()
    @State private var mlxRuntime = MLXRuntime()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(store)
                .environment(generator)
                .environment(mlxRuntime)
                .frame(minWidth: 900, minHeight: 620)
                #if DEBUG
                .task { SmokeTest.runIfRequested(store: store, generator: generator) }
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
    case generate = "Generate"
    case gallery = "Gallery"
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

    func restore(_ record: GenerationRecord) {
        isRestoring = selectedModelID != record.modelID
        request = record.request
        selectedModelID = record.modelID
        section = .generate
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(ModelStore.self) private var store

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
        .onAppear {
            if store.installed.isEmpty { app.section = .models }
        }
    }
}
