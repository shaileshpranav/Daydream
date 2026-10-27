import Foundation
import Observation

/// Installed models live in ~/Library/Application Support/CoreMLImageGen/Models/<id>/,
/// each with a model.json describing it next to the compiled .mlmodelc resources.
@MainActor
@Observable
final class ModelStore {
    struct DownloadState {
        var fraction: Double
        var task: Task<Void, Never>?
    }

    private(set) var installed: [InstalledModel] = []
    private(set) var downloads: [String: DownloadState] = [:]
    var lastError: String?

    let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CoreMLImageGen/Models", directoryHint: .isDirectory)
    }()

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        installed = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appending(path: "model.json")),
                  var model = try? JSONDecoder().decode(InstalledModel.self, from: data)
            else { return nil }
            model.folder = dir
            return model
        }
        .sorted { $0.name < $1.name }
    }

    func isInstalled(_ entry: CatalogEntry) -> Bool {
        installed.contains { $0.id == entry.id }
    }

    func model(id: String?) -> InstalledModel? {
        installed.first { $0.id == id }
    }

    func sizeOnDisk(_ model: InstalledModel) -> Int64 {
        Self.directorySize(model.folder)
    }

    // MARK: Changing models

    func setComputeUnits(_ units: ComputeUnitsChoice, for model: InstalledModel) {
        var updated = model
        updated.computeUnits = units
        try? Self.writeManifest(updated, to: model.folder)
        refresh()
    }

    func delete(_ model: InstalledModel) {
        do {
            try FileManager.default.removeItem(at: model.folder)
        } catch {
            lastError = "Couldn't delete \(model.name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Copies a folder of compiled resources (e.g. from tools/convert) into the store.
    func importFolder(_ source: URL, name: String, kind: ModelKind, resolution: Int, loras: [FusedLoRA]? = nil) {
        let fm = FileManager.default
        guard let resources = Self.findResourceDir(in: source) else {
            lastError = "No vocab.json / *.mlmodelc found in \(source.path). Point at the folder holding the compiled models."
            return
        }
        let id = "import-" + name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" } + "-\(Int(Date().timeIntervalSince1970))"
        let dest = root.appending(path: id, directoryHint: .isDirectory)
        do {
            try fm.copyItem(at: resources, to: dest)
            let units: ComputeUnitsChoice = kind == .sdxl ? .cpuAndGPU : .cpuAndNeuralEngine
            try Self.writeManifest(InstalledModel(id: id, name: name, kind: kind, computeUnits: units,
                                                  resolution: resolution, loras: loras), to: dest)
        } catch {
            lastError = "Import failed: \(error.localizedDescription)"
            try? fm.removeItem(at: dest)
        }
        refresh()
    }

    // MARK: Downloading

    func download(_ entry: CatalogEntry) {
        guard downloads[entry.id] == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performDownload(entry)
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.lastError = "Download of \(entry.name) failed: \(error.localizedDescription)"
            }
            self.downloads[entry.id] = nil
            self.refresh()
        }
        downloads[entry.id] = DownloadState(fraction: 0, task: task)
    }

    func cancelDownload(_ entry: CatalogEntry) {
        downloads[entry.id]?.task?.cancel()
    }

    private func performDownload(_ entry: CatalogEntry) async throws {
        let fm = FileManager.default
        let staging = root.appending(path: ".staging-\(entry.id)", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files: [HFFile]
        if let zip = entry.zip {
            files = try await HuggingFace.listFiles(repo: entry.repo, prefix: zip).filter { $0.path == zip }
        } else {
            let prefix = entry.folder ?? ""
            let exclude = (entry.exclude ?? []).map { prefix + $0 }
            files = try await HuggingFace.listFiles(repo: entry.repo, prefix: prefix)
                .filter { file in !exclude.contains { file.path.hasPrefix($0) } }
        }
        guard !files.isEmpty else { throw URLError(.fileDoesNotExist) }

        let total = Double(files.reduce(0) { $0 + $1.size })
        let counter = ByteCounter()
        for file in files {
            try Task.checkCancellation()
            let relative = entry.zip != nil ? file.path : String(file.path.dropFirst((entry.folder ?? "").count))
            try await FileDownloader.download(HuggingFace.resolveURL(repo: entry.repo, path: file.path),
                                              to: staging.appending(path: relative)) { bytes in
                Task { @MainActor in
                    counter.bytes += bytes
                    self.downloads[entry.id]?.fraction = Double(counter.bytes) / total
                }
            }
        }

        var resources = staging
        if let zip = entry.zip {
            let archive = staging.appending(path: zip)
            let extracted = staging.appending(path: "extracted", directoryHint: .isDirectory)
            try await Self.unzip(archive, to: extracted)
            try fm.removeItem(at: archive)
            guard let dir = Self.findResourceDir(in: extracted) else { throw CocoaError(.fileReadCorruptFile) }
            resources = dir
        }

        let dest = root.appending(path: entry.id, directoryHint: .isDirectory)
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: resources, to: dest)
        try Self.writeManifest(InstalledModel(id: entry.id, name: entry.name, kind: entry.kind,
                                              computeUnits: entry.computeUnits, resolution: entry.resolution), to: dest)
    }

    // MARK: Helpers

    private static func writeManifest(_ model: InstalledModel, to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(model).write(to: folder.appending(path: "model.json"))
    }

    /// The directory holding the compiled models: the first one (breadth-first) containing vocab.json.
    static func findResourceDir(in root: URL) -> URL? {
        let fm = FileManager.default
        var queue = [root]
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            if fm.fileExists(atPath: dir.appending(path: "vocab.json").path) { return dir }
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            queue += children.filter {
                $0.pathExtension != "mlmodelc"
                    && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
        }
        return nil
    }

    private static func unzip(_ archive: URL, to dest: URL) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", archive.path, dest.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unzipping \(archive.lastPathComponent) failed"])
            }
        }.value
    }

    nonisolated static func directorySize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            let v = try? file.resourceValues(forKeys: keys)
            if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

@MainActor
private final class ByteCounter {
    var bytes: Int64 = 0
}

struct HFFile: Decodable {
    let type: String
    let path: String
    let size: Int64
}

enum HuggingFace {
    static func listFiles(repo: String, prefix: String) async throws -> [HFFile] {
        var components = URLComponents(string: "https://huggingface.co/api/models/\(repo)/tree/main")!
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Hugging Face returned HTTP \(http.statusCode) listing \(repo)"])
        }
        return try JSONDecoder().decode([HFFile].self, from: data)
            .filter { $0.type == "file" && $0.path.hasPrefix(prefix) }
    }

    static func resolveURL(repo: String, path: String) -> URL {
        let encoded = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
    }
}
