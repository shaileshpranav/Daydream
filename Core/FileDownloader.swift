import Foundation

/// Downloads one URL to a destination file, reporting bytes written.
/// Uses a delegate-based session so multi-GB files never sit in memory.
///
/// A dropped connection throws a `URLError` whose `downloadTaskResumeData` can be passed
/// back as `resumeData` to continue from where it stopped instead of starting over.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private var onProgress: ((Int64) -> Void)?
    private var session: URLSession!
    /// Bytes not yet reported. URLSession calls back every ~64 KB; reporting each one
    /// would send ~100k updates to the main thread for a 6 GB model.
    private var unreported: Int64 = 0
    private static let reportEvery: Int64 = 8 << 20

    static func download(
        _ url: URL,
        to destination: URL,
        resumeData: Data? = nil,
        onProgress: @escaping (Int64) -> Void
    ) async throws {
        let downloader = FileDownloader()
        try await downloader.run(url, to: destination, resumeData: resumeData, onProgress: onProgress)
    }

    private func run(_ url: URL, to destination: URL, resumeData: Data?,
                     onProgress: @escaping (Int64) -> Void) async throws {
        self.destination = destination
        self.onProgress = onProgress
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                continuation = c
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func flushProgress() {
        if unreported > 0 { onProgress?(unreported) }
        unreported = 0
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        unreported += bytesWritten
        if unreported >= Self.reportEvery { flushProgress() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        flushProgress()
        // The temp file is deleted when this method returns, so move it now.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "")"])
            }
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            flushProgress()
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
