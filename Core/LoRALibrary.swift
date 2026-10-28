import Foundation
import Observation

/// The LoRAs in Models/Loras, with what each is for and per-LoRA settings the user keeps
/// (default strength, trigger words). Settings live in Loras/.lora-settings.json, keyed
/// by the file's path inside the folder.
@MainActor
@Observable
final class LoRALibrary {
    struct Settings: Codable, Equatable {
        var defaultScale: Double = 1.0
        var triggerWords: String = ""
    }

    struct Item: Identifiable, Equatable {
        let url: URL
        /// Path inside the Loras folder without extension, e.g. "flux2/Style".
        let name: String
        let result: LoRAInspector.Result
        let bytes: Int64
        let suggestedTriggers: [String]
        /// Training steps, when the trainer recorded them.
        let trainingSteps: Int?

        var id: String { url.path }
        var base: LoRABase? {
            if case .known(let base) = result { base } else { nil }
        }
    }

    private(set) var items: [Item] = []
    private(set) var settings: [String: Settings] = [:]
    /// Downloads in progress, by repo, as a fraction done. Kept here rather than in a view
    /// so progress survives switching sections.
    private(set) var downloads: [String: Double] = [:]
    var lastError: String?

    private var settingsURL: URL { ModelStore.lorasFolder.appending(path: ".lora-settings.json") }

    init() {
        loadSettings()
        reload()
    }

    /// Rescans the folder. Headers are cached by path and modification date, so this is cheap.
    func reload() {
        items = ModelStore.libraryLoRAs().map { url in
            let metadata = LoRAInspector.metadata(file: url)
            let steps = metadata["training_info"]
                .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .flatMap { $0["step"] as? Int }
                ?? metadata["ss_steps"].flatMap(Int.init)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return Item(url: url, name: Self.relativeName(url), result: LoRAInspector.inspect(file: url),
                        bytes: Int64(size), suggestedTriggers: LoRAInspector.suggestedTriggers(metadata),
                        trainingSteps: steps)
        }
    }

    func item(path: String?) -> Item? {
        items.first { $0.id == path }
    }

    func settings(for url: URL) -> Settings {
        settings[Self.key(url)] ?? Settings()
    }

    func update(_ newSettings: Settings, for url: URL) {
        settings[Self.key(url)] = newSettings
        saveSettings()
    }

    /// Copies LoRA files into the Loras folder.
    func importFiles(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls where url.pathExtension.lowercased() == "safetensors" {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let dest = ModelStore.lorasFolder.appending(path: url.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) { throw RuntimeError("\(url.lastPathComponent) is already in the Loras folder.") }
                try fm.copyItem(at: url, to: dest)
            } catch {
                lastError = error.localizedDescription
            }
        }
        reload()
    }

    /// Downloads a LoRA's .safetensors from a Hugging Face repo into the Loras folder.
    func download(repo: String, progress: @escaping @MainActor (Double) -> Void) async throws -> Item? {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        downloads[repo] = 0
        defer { downloads[repo] = nil }
        let (file, _, _) = try await LoRAInspector.inspect(repo: repo)
        let size = try await HuggingFace.listFiles(repo: repo, prefix: file).first { $0.path == file }?.size ?? 0
        let folder = ModelStore.lorasFolder.appending(path: repo.replacingOccurrences(of: "/", with: "__"))
        let dest = folder.appending(path: (file as NSString).lastPathComponent)
        let received = ReceivedBytes()
        try await FileDownloader.download(HuggingFace.resolveURL(repo: repo, path: file), to: dest) { bytes in
            Task { @MainActor in
                received.count += bytes
                guard size > 0 else { return }
                let fraction = Double(received.count) / Double(size)
                if self.downloads[repo] != nil { self.downloads[repo] = fraction }
                progress(fraction)
            }
        }
        reload()
        return items.first { $0.url.standardizedFileURL == dest.standardizedFileURL }
    }

    func moveToTrash(_ item: Item) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            settings[Self.key(item.url)] = nil
            saveSettings()
        } catch {
            lastError = "Couldn't move \(item.name) to the Trash: \(error.localizedDescription)"
        }
        reload()
    }

    // MARK: Persistence

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? JSONDecoder().decode([String: Settings].self, from: data) else { return }
        settings = decoded
    }

    private func saveSettings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(settings).write(to: settingsURL)
        } catch {
            lastError = "Couldn't save LoRA settings: \(error.localizedDescription)"
        }
    }

    private static func key(_ url: URL) -> String {
        let root = ModelStore.lorasFolder.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)).trimmingCharacters(in: ["/"]) : path
    }

    /// File name without extension, with its subfolder if it's in one ("flux2/Style").
    static func relativeName(_ url: URL) -> String {
        (key(url) as NSString).deletingPathExtension
    }
}

@MainActor
private final class ReceivedBytes {
    var count: Int64 = 0
}
