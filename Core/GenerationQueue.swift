import AppKit
import Foundation
import Observation
import UserNotifications

/// One image to make: the model and settings are captured when it's queued, so editing
/// the prompt afterwards doesn't change jobs already waiting.
struct QueuedJob: Identifiable, Equatable {
    enum State: Equatable {
        case pending
        case running
        case done(GenerationRecord)
        case cancelled
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .pending, .running: false
            default: true
            }
        }
    }

    let id = UUID()
    let model: InstalledModel
    let request: GenerationRequest
    /// Fixed preview interval (tests); nil follows the live preview setting when the job starts.
    let previewEvery: Int?
    var state: State = .pending
}

/// Runs queued jobs one at a time through the single `Generator`, so only one model is
/// ever resident. Jobs run in order; consecutive jobs on the same model and LoRAs reuse
/// the loaded weights.
@MainActor
@Observable
final class GenerationQueue {
    private(set) var jobs: [QueuedJob] = []
    private(set) var isRunning = false
    private let generator: Generator

    init(generator: Generator) {
        self.generator = generator
    }

    var pendingCount: Int { jobs.count { $0.state == .pending } }
    var runningJob: QueuedJob? { jobs.first { $0.state == .running } }
    var hasFinished: Bool { jobs.contains { $0.state.isFinished } }

    /// Queues `count` images. With `count > 1` the seeds count up from the request's
    /// seed (42, 43, 44…), so each image differs and any one can be reproduced.
    func enqueue(model: InstalledModel, request: GenerationRequest, count: Int = 1, previewEvery: Int? = nil) {
        for i in 0..<max(1, count) {
            var r = request
            r.seed = request.seed &+ UInt32(i)
            jobs.append(QueuedJob(model: model, request: r, previewEvery: previewEvery))
        }
        if count > 1 || isRunning { QueueNotifier.requestPermissionIfNeeded() }
        updateDockBadge()
        if !isRunning { Task { await runQueue() } }
    }

    func remove(_ id: QueuedJob.ID) {
        jobs.removeAll { $0.id == id && $0.state != .running }
        updateDockBadge()
    }

    /// Moves a pending job up or down among the pending jobs.
    func move(_ id: QueuedJob.ID, by offset: Int) {
        guard let from = jobs.firstIndex(where: { $0.id == id && $0.state == .pending }) else { return }
        let to = from + offset
        guard jobs.indices.contains(to), jobs[to].state == .pending else { return }
        jobs.swapAt(from, to)
    }

    /// Stops the running job; the queue then continues with the next one.
    func cancelCurrent() {
        generator.cancel()
    }

    /// Stops the running job and drops everything still waiting.
    func cancelAll() {
        jobs.removeAll { $0.state == .pending }
        generator.cancel()
        updateDockBadge()
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func runQueue() async {
        isRunning = true
        var finished = 0, failed = 0
        defer {
            isRunning = false
            updateDockBadge()
            QueueNotifier.queueFinished(images: finished, failed: failed)
        }
        while let index = jobs.firstIndex(where: { $0.state == .pending }) {
            jobs[index].state = .running
            updateDockBadge()
            let job = jobs[index]
            // The preview setting is read now, so the toolbar's toggle reaches jobs already waiting.
            let previewEvery = job.previewEvery ?? UserDefaults.standard.integer(forKey: Self.previewEveryKey)
            let outcome = await generator.generate(model: job.model, request: job.request, previewEvery: previewEvery)
            // The job may have moved while it ran (others removed/reordered); find it again.
            guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            switch outcome {
            case .saved(let record):
                jobs[i].state = .done(record)
                finished += 1
            case .cancelled:
                jobs[i].state = .cancelled
            case .failed(let message):
                jobs[i].state = .failed(message)
                failed += 1
            }
        }
    }

    static let dockBadgeKey = "dockBadge"
    /// Steps between live previews; 0 turns them off.
    static let previewEveryKey = "previewEvery"
    /// The interval to go back to when previews are turned on again from the toolbar.
    static let lastPreviewEveryKey = "lastPreviewEvery"

    /// Shows how many images are still to come on the Dock icon.
    func updateDockBadge() {
        let remaining = UserDefaults.standard.bool(forKey: Self.dockBadgeKey)
            ? pendingCount + (runningJob == nil ? 0 : 1) : 0
        NSApp?.dockTile.badgeLabel = remaining > 0 ? "\(remaining)" : nil
    }
}

/// Tells the user a queue run finished while they were in another app.
@MainActor
enum QueueNotifier {
    static let enabledKey = "notifyQueueFinished"
    private static var authorized = false
    private static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Asks once, the first time a batch is queued.
    static func requestPermissionIfNeeded() {
        guard enabled, !authorized else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in authorized = granted }
        }
    }

    static func queueFinished(images: Int, failed: Int) {
        // Only worth interrupting for when the user isn't looking and it took a while.
        guard enabled, authorized, images + failed > 1, NSApp?.isActive == false else { return }
        let content = UNMutableNotificationContent()
        content.title = "Queue finished"
        content.body = failed == 0
            ? "\(images) image\(images == 1 ? "" : "s") ready."
            : "\(images) image\(images == 1 ? "" : "s") ready, \(failed) failed."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
