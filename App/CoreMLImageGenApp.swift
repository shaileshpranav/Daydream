import SwiftUI

@main
struct CoreMLImageGenApp: App {
    @State private var app = AppState()
    @State private var store = ModelStore()
    @State private var generator: Generator
    @State private var queue: GenerationQueue
    @State private var mlxRuntime = MLXRuntime()
    @State private var loraLibrary = LoRALibrary()
    @State private var promptModels = PromptModelStore()
    @State private var upscaler = Upscaler()
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.dark

    init() {
        UserDefaults.standard.register(defaults: SettingsDefaults.registered)
        // Step pictures from an edit the app quit in the middle of.
        EditSession.removeLeftovers()
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
                .environment(promptModels)
                .environment(upscaler)
                .frame(minWidth: 1040, minHeight: 640)
                .tint(Theme.accent)
                // Set on the app rather than with preferredColorScheme, which can't go back to
                // following macOS once set.
                .onChange(of: appearance, initial: true) { NSApp.appearance = appearance.nsAppearance }
                #if DEBUG
                .task { SmokeTest.runIfRequested(store: store, generator: generator, queue: queue, app: app) }
                #endif
        }
        // No title bar or toolbar: each section draws its own header bar, so the top of
        // the window stays put when switching sections.
        .windowStyle(.hiddenTitleBar)
        // Settings is a section of the main window, not a separate window: ⌘, goes there.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { app.section = .settings }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceChoice.allCases) { Text($0.label).tag($0) }
                }
                Divider()
            }
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case generate = "Create"
    case gallery = "My Pictures"
    case edit = "Edit"
    case queue = "Queue"
    case models = "Models"
    case settings = "Settings"

    var id: String { rawValue }

    /// The sections at the top of the side rail (⌥⌘1–⌥⌘4); Settings sits at the bottom.
    static var main: [AppSection] { allCases.filter { $0 != .settings } }

    var icon: String {
        switch self {
        case .generate: "wand.and.stars"
        case .gallery: "photo.on.rectangle"
        case .edit: "paintbrush.pointed"
        case .queue: "list.bullet.rectangle"
        case .models: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

/// UI state shared between sections, e.g. so the gallery can send settings back to Generate.
@MainActor
@Observable
final class AppState {
    #if DEBUG
    /// `-section Settings` opens on that section, for checking a page without clicking to it.
    var section = AppSection(rawValue: UserDefaults.standard.string(forKey: "section") ?? "") ?? .generate
    #else
    var section: AppSection = .generate
    #endif
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

    /// The model Create last preloaded, so returning to Create doesn't load it again after
    /// it was freed. Picking a different model preloads that one.
    var preloadedModelID: String?

    /// A finished image the user clicked in the queue, shown instead of the latest one.
    var viewedRecord: GenerationRecord?

    /// True while a debug smoke test drives the app, so it doesn't preload models itself.
    var automationRunning = ["smokeTest", "queueTest", "img2imgTest", "loraTest", "enhanceTest", "preloadTest",
                             "precisionTest", "managerTest", "previewTest", "mossTest", "snapshots", "livePreviewTest", "upscaleTest", "editTest"]
        .contains { UserDefaults.standard.object(forKey: $0) != nil }

    var startImageError: String?

    /// The picture open in the Edit section, kept while other sections are shown.
    var editSession: EditSession?
    /// A picture asked to be opened in Edit; the Edit section opens it (asking first if the
    /// open picture has unsaved steps).
    var editRequest: EditRequest?
    var editError: String?

    enum EditRequest: Equatable {
        case record(GenerationRecord)
        case file(URL)
    }

    func openEditor(_ record: GenerationRecord) {
        editRequest = .record(record)
        section = .edit
    }

    func openEditor(file url: URL) {
        editRequest = .file(url)
        section = .edit
    }

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
    @Environment(Generator.self) private var generator
    @AppStorage(GenerationQueue.previewEveryKey) private var previewEvery = 5

    var body: some View {
        HStack(spacing: 0) {
            SideRail()
            Divider()
            Group {
                switch app.section {
                case .generate: GenerateView()
                case .gallery: GalleryView()
                case .edit: EditView()
                case .queue: QueuePage()
                case .models: ModelManagerView()
                case .settings: SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.base)
        }
        .background(Theme.base.ignoresSafeArea())
        // Here rather than in Create or Settings, so a change from either reaches the
        // picture being made.
        .onChange(of: previewEvery) { generator.setPreviewEvery(previewEvery) }
    }
}

/// The narrow icon bar down the left edge that switches sections (⌥⌘1–⌥⌘4).
private struct SideRail: View {
    @Environment(AppState.self) private var app
    @Environment(GenerationQueue.self) private var queue

    var body: some View {
        VStack(spacing: 6) {
            AppMark()
                .help("Daydream")
                .padding(.top, 2)
            Divider()
                .frame(width: 26)
                .padding(.vertical, 4)
            ForEach(Array(AppSection.main.enumerated()), id: \.element) { index, section in
                Button(section.rawValue, systemImage: section.icon) { app.section = section }
                    .buttonStyle(IconButtonStyle(isSelected: app.section == section, size: 38))
                    .help("\(section.rawValue) (⌥⌘\(index + 1))")
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                    // Not a Tab stop: with keyboard navigation on, macOS would otherwise put
                    // its focus ring on the first rail button whenever the window opens.
                    // Sections have shortcuts instead.
                    .focusable(false)
                    .overlay(alignment: .topTrailing) {
                        if section == .queue, queue.isRunning {
                            Text("\(queue.pendingCount + 1)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 15, minHeight: 15)
                                .background(Theme.create, in: Capsule())
                                .offset(x: 3, y: -3)
                        }
                    }
            }
            Spacer()
            Button(AppSection.settings.rawValue, systemImage: AppSection.settings.icon) { app.section = .settings }
                .buttonStyle(IconButtonStyle(isSelected: app.section == .settings, size: 38))
                .help("Settings (⌘,)")
                .focusable(false)
        }
        .padding(.vertical, 10)
        .frame(width: 54)
        .background(Theme.base)
    }
}

/// The Queue section: every job, running, waiting and finished.
private struct QueuePage: View {
    @Environment(GenerationQueue.self) private var queue
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Queue").font(.headline)
                Spacer()
                if queue.isRunning {
                    Button("Stop All", role: .destructive) { queue.cancelAll() }
                        .controlSize(.small)
                }
            }
            if queue.jobs.isEmpty {
                ContentUnavailableView {
                    Label("The queue is empty", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Pictures you ask for wait here while they're made, one at a time.")
                } actions: {
                    Button("Create a Picture") { app.section = .generate }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxHeight: .infinity)
            } else {
                QueueView()
                    .frame(maxWidth: 820, maxHeight: .infinity, alignment: .top)
                    .padding()
            }
        }
        .navigationTitle("Queue")
    }
}
