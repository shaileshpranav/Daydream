import Foundation
import Observation

/// The Python environment that runs MLX models: a venv with a pinned mflux (image models)
/// and mlx-lm (the prompt rewriter's language model), created on request in
/// ~/Library/Application Support/CoreMLImageGen/MLX. Only MLX models need it.
@MainActor
@Observable
final class MLXRuntime {
    enum Status: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    /// Bump together with mlx_worker.py when the worker needs a newer mflux or mlx-lm.
    nonisolated static let packages = ["mflux==0.24.0", "mlx-lm==0.32.2"]
    nonisolated static var packageSummary: String { packages.joined(separator: " ") }

    nonisolated static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "CoreMLImageGen/MLX", directoryHint: .isDirectory)
    }()
    nonisolated static var python: URL { root.appending(path: "venv/bin/python") }
    nonisolated static var logURL: URL { root.appending(path: "worker.log") }
    nonisolated private static var marker: URL { root.appending(path: "installed.txt") }

    nonisolated static var workerScript: URL? {
        Bundle.main.url(forResource: "mlx_worker", withExtension: "py")
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path)
            && (try? String(contentsOf: marker, encoding: .utf8)) == packageSummary
    }

    private(set) var status: Status = MLXRuntime.isInstalled ? .installed : .notInstalled

    func install() {
        switch status {
        case .notInstalled, .failed: startInstall()
        case .installing, .installed: break
        }
    }

    private func startInstall() {
        status = .installing("Finding Python 3.11+…")
        Task.detached {
            do {
                try await Self.performInstall { line in
                    Task { @MainActor in self.status = .installing(line) }
                }
                await MainActor.run { self.status = .installed }
            } catch {
                await MainActor.run { self.status = .failed(error.localizedDescription) }
            }
        }
    }

    nonisolated private static func performInstall(progress: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        guard let systemPython = findPython() else {
            throw RuntimeError("Python 3.11 or newer is required. Install it with: brew install python@3.12")
        }
        let venv = root.appending(path: "venv")
        if !fm.isExecutableFile(atPath: python.path) {
            progress("Creating Python environment…")
            try run(systemPython, ["-m", "venv", venv.path], progress: progress)
        }
        progress("Installing \(packages.joined(separator: ", ")) (downloads MLX; a few hundred MB)…")
        try run(python.path, ["-m", "pip", "install", "--upgrade", "pip"], progress: progress)
        try run(python.path, ["-m", "pip", "install"] + packages, progress: progress)
        progress("Checking the installation…")
        try run(python.path, ["-I", "-c", "import mflux, mlx.core, mlx_lm"], progress: progress)
        try packageSummary.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// A Homebrew or python.org Python new enough for mflux (macOS's own python3 is 3.9).
    nonisolated private static func findPython() -> String? {
        let versions = ["3.13", "3.12", "3.11"]
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Frameworks/Python.framework/Versions/Current/bin"]
        for version in versions {
            for dir in dirs {
                let path = "\(dir)/python\(version)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String],
                                        progress: @escaping @Sendable (String) -> Void) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        var tail: [String] = []
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            for line in text.split(whereSeparator: \.isNewline) where !line.isEmpty {
                progress(String(line.prefix(120)))
                tail.append(String(line))
                if tail.count > 20 { tail.removeFirst() }
            }
        }
        try process.run()
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        if process.terminationStatus != 0 {
            throw RuntimeError("\(URL(filePath: executable).lastPathComponent) \(arguments.prefix(3).joined(separator: " ")) failed:\n"
                               + tail.suffix(5).joined(separator: "\n"))
        }
    }
}

struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
