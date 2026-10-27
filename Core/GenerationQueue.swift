import Foundation
import Observation

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
    let previewEvery: Int
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
    func enqueue(model: InstalledModel, request: GenerationRequest, count: Int = 1, previewEvery: Int) {
        for i in 0..<max(1, count) {
            var r = request
            r.seed = request.seed &+ UInt32(i)
            jobs.append(QueuedJob(model: model, request: r, previewEvery: previewEvery))
        }
        if !isRunning { Task { await runQueue() } }
    }

    func remove(_ id: QueuedJob.ID) {
        jobs.removeAll { $0.id == id && $0.state != .running }
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
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func runQueue() async {
        isRunning = true
        defer { isRunning = false }
        while let index = jobs.firstIndex(where: { $0.state == .pending }) {
            jobs[index].state = .running
            let job = jobs[index]
            let outcome = await generator.generate(model: job.model, request: job.request, previewEvery: job.previewEvery)
            // The job may have moved while it ran (others removed/reordered); find it again.
            guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { continue }
            switch outcome {
            case .saved(let record): jobs[i].state = .done(record)
            case .cancelled: jobs[i].state = .cancelled
            case .failed(let message): jobs[i].state = .failed(message)
            }
        }
    }
}
