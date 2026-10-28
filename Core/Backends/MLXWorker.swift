import Foundation

/// One mlx_worker.py process and its JSON-lines pipe. Image models (MLXBackend) and the
/// prompt rewriter (MLXPromptRewriter) each run their own, so either can be freed alone.
final class MLXWorker {
    struct Stopped: Error {
        let status: Int32?
    }

    private var process: Process?
    private var input: FileHandle?
    private var reader: LineReader?

    var isRunning: Bool { process?.isRunning == true }
    var processIdentifier: Int32? { process?.processIdentifier }

    func start() throws {
        guard let script = MLXRuntime.workerScript else {
            throw RuntimeError("mlx_worker.py is missing from the app bundle.")
        }
        let fm = FileManager.default
        if !fm.fileExists(atPath: MLXRuntime.logURL.path) {
            fm.createFile(atPath: MLXRuntime.logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: MLXRuntime.logURL)
        log.seekToEndOfFile()

        let process = Process()
        process.executableURL = MLXRuntime.python
        process.arguments = ["-I", "-u", script.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["TOKENIZERS_PARALLELISM"] = "false"
        process.environment = env
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = log  // mflux / mlx-lm logs and tracebacks, for debugging
        try process.run()

        self.process = process
        input = stdinPipe.fileHandleForWriting
        reader = LineReader(handle: stdoutPipe.fileHandleForReading)
        let ready = try? nextEvent()
        guard ready?["event"] as? String == "ready" else {
            throw RuntimeError("MLX worker didn't start. See \(MLXRuntime.logURL.path).")
        }
    }

    func send(_ message: [String: Any]) throws {
        guard let input else { throw RuntimeError("MLX worker isn't running.") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    /// The next event line. Throws `Stopped` (and cleans up) when the process has exited.
    func nextEvent() throws -> [String: Any] {
        guard let line = reader?.readLine() else {
            let status = process?.terminationStatus
            terminate()
            throw Stopped(status: status)
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Terminating the process is the surest way to free all of its memory.
    func terminate() {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        input = nil
        reader = nil
    }

    deinit { terminate() }
}

/// Blocking line reader over a pipe; returns nil at end of file.
private final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.availableData  // blocks until data or EOF
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
    }
}
