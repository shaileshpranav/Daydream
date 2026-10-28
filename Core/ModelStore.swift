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
        /// What's being downloaded (a catalog entry, or one made for a Hugging Face repo).
        var entry: CatalogEntry
    }

    private(set) var installed: [InstalledModel] = []
    private(set) var downloads: [String: DownloadState] = [:]
    var lastError: String?

    let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CoreMLImageGen/Models", directoryHint: .isDirectory)
    }()

    /// Drop LoRA .safetensors files here (subfolders are fine) to pick them in Generate.
    nonisolated static var lorasFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CoreMLImageGen/Models/Loras", directoryHint: .isDirectory)
    }

    init() {
        try? FileManager.default.createDirectory(at: Self.lorasFolder, withIntermediateDirectories: true)
        refresh()
    }

    /// The .safetensors files in the Loras folder, sorted by name. Read fresh each time
    /// so files dropped in while the app runs show up.
    nonisolated static func libraryLoRAs() -> [URL] {
        guard let e = FileManager.default.enumerator(at: lorasFolder, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "safetensors" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
        downloads[entry.id] = DownloadState(fraction: 0, task: task, entry: entry)
    }

    /// Installs an mflux-format model from any Hugging Face repo, e.g.
    /// "mflux-community/flux2-klein-9b-mflux-q4". Returns the entry being downloaded.
    @discardableResult
    func installFromHuggingFace(repo: String, family: MLXFamily) async throws -> CatalogEntry {
        let repo = repo.trimmingCharacters(in: .whitespaces)
        let files = try await HuggingFace.listFiles(repo: repo, prefix: "")
        guard files.contains(where: { $0.path.hasSuffix(".safetensors") }) else {
            throw RuntimeError("\(repo) has no .safetensors weights, so it isn't an mflux model.")
        }
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        let slug = repo.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let quant = MLXFamilies.quantization(repo: repo).map { ", \($0)" } ?? ""
        let entry = CatalogEntry(
            id: "hf-" + String(slug), name: "\(family.label) (MLX\(quant))", kind: .mlx, repo: repo,
            zip: nil, folder: "", exclude: [".gitattributes", "README.md"], computeUnits: .cpuAndGPU,
            resolution: family.resolution, approxGB: Double(bytes) / 1e9,
            notes: "Installed from \(repo).", license: nil, mlxFamily: family.id, defaults: family.defaults)
        guard !installed.contains(where: { $0.id == entry.id }) else {
            throw RuntimeError("\(repo) is already installed.")
        }
        download(entry)
        return entry
    }

    // MARK: Editing (model manager)

    /// Saves edits to a model's name, defaults, resolution or compute units.
    func update(_ model: InstalledModel) {
        do {
            try Self.writeManifest(model, to: model.folder)
        } catch {
            lastError = "Couldn't save \(model.name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Moves a model to the Trash (recoverable, unlike deleting outright).
    func moveToTrash(_ model: InstalledModel) {
        do {
            try FileManager.default.trashItem(at: model.folder, resultingItemURL: nil)
        } catch {
            lastError = "Couldn't move \(model.name) to the Trash: \(error.localizedDescription)"
        }
        refresh()
    }

    /// Free space on the disk holding the models.
    var freeDiskBytes: Int64? {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
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

        try await HuggingFace.download(repo: entry.repo, files: files, into: staging, relativePath: { file in
            entry.zip != nil ? file.path : String(file.path.dropFirst((entry.folder ?? "").count))
        }) { fraction in
            self.downloads[entry.id]?.fraction = fraction
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
                                              computeUnits: entry.computeUnits, resolution: entry.resolution,
                                              mlxFamily: entry.mlxFamily, defaults: entry.defaults,
                                              source: entry.repo), to: dest)
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

    /// Downloads `files` from `repo` into `folder` (at `relativePath(file)`), reporting the
    /// fraction done. Multi-GB downloads over a flaky connection: a file is retried a few
    /// times instead of failing the whole model on one dropped connection, resuming from the
    /// byte it stopped at when the server allows it (Hugging Face does).
    @MainActor
    static func download(repo: String, files: [HFFile], into folder: URL,
                         relativePath: (HFFile) -> String = { $0.path },
                         onProgress: @escaping @MainActor (Double) -> Void) async throws {
        let total = Double(files.reduce(0) { $0 + $1.size })
        let counter = ByteCounter()
        for file in files {
            try Task.checkCancellation()
            var attempt = 0
            var resumeData: Data?
            while true {
                attempt += 1
                let before = counter.bytes
                do {
                    try await FileDownloader.download(resolveURL(repo: repo, path: file.path),
                                                      to: folder.appending(path: relativePath(file)),
                                                      resumeData: resumeData) { bytes in
                        Task { @MainActor in
                            counter.bytes += bytes
                            onProgress(Double(counter.bytes) / total)
                        }
                    }
                    break
                } catch let error as URLError where error.code != .cancelled && attempt < 8 {
                    resumeData = error.downloadTaskResumeData
                    // Without resume data the file starts over, so its bytes are counted again.
                    if resumeData == nil { counter.bytes = before }
                    try await Task.sleep(for: .seconds(min(2 * attempt, 10)))
                }
            }
        }
    }

    static func resolveURL(repo: String, path: String) -> URL {
        let encoded = path.split(separator: "/")
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)")!
    }
}
