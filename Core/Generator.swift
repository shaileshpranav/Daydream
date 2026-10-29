import CoreGraphics
import Foundation
import Observation

/// Runs generations on a background queue and keeps at most one model resident.
/// On a 16 GB Mac, holding two pipelines at once is the quickest way to swap.
@MainActor
@Observable
final class Generator {
    enum Phase: Equatable {
        case idle
        case loading(String)
        case generating(step: Int, total: Int)
    }

    private(set) var phase: Phase = .idle
    private(set) var preview: CGImage?
    private(set) var lastImage: CGImage?
    private(set) var lastRecord: GenerationRecord?
    private(set) var loadedModelID: String?
    /// Estimated seconds left in the current image, once a couple of steps have run.
    private(set) var etaSeconds: Double?
    var lastError: String?

    var isBusy: Bool { phase != .idle }

    /// Minutes with nothing to do before the resident model is freed; 0 keeps it loaded.
    static let idleUnloadKey = "unloadIdleMinutes"

    private var backend: ImageBackend?
    private let queue = DispatchQueue(label: "CoreMLImageGen.inference", qos: .userInitiated)
    private let cancelFlag = CancelFlag()
    private var idleUnload: Task<Void, Never>?

    // Loads and generations take turns: a generate that arrives while a preload is
    // running waits for it instead of failing.
    private var workLocked = false
    private var workWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireWork() async {
        idleUnload?.cancel()
        if !workLocked {
            workLocked = true
            return
        }
        await withCheckedContinuation { workWaiters.append($0) }
    }

    private func releaseWork() {
        if workWaiters.isEmpty {
            workLocked = false
            restartIdleTimer()
        } else {
            workWaiters.removeFirst().resume()
        }
    }

    func cancel() {
        cancelFlag.set(true)
    }

    /// Frees the resident model, e.g. before a large download or when switching.
    func unloadModel() {
        guard !isBusy, !workLocked, let backend else { return }
        queue.async { backend.unload() }
        self.backend = nil
        loadedModelID = nil
    }

    /// Passes a preview setting change to the picture being made, so turning previews on or
    /// off applies from its next step rather than the next picture.
    func setPreviewEvery(_ every: Int) {
        guard case .generating = phase, let backend else { return }
        backend.setPreviewEvery(every)
    }

    /// Starts the countdown to freeing the model (Settings → Speed & Memory). Called after
    /// each load or picture, and when the setting changes.
    func restartIdleTimer() {
        idleUnload?.cancel()
        let minutes = UserDefaults.standard.integer(forKey: Self.idleUnloadKey)
        guard minutes > 0, backend != nil else { return }
        idleUnload = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.unloadModel()
        }
    }

    /// Loads `model` ahead of time so the first Generate starts straight away.
    /// Does nothing if it's already loaded (with the same LoRAs).
    func preload(model: InstalledModel, request: GenerationRequest) async {
        await acquireWork()
        defer { releaseWork() }
        if let backend, backend.model == model, loadedModelID == model.id, !backend.needsReload(for: request) {
            return
        }
        do {
            _ = try await prepareBackend(for: model, request: request)
        } catch {
            lastError = error.localizedDescription
        }
        phase = .idle
    }

    enum Outcome: Equatable {
        case saved(GenerationRecord)
        case cancelled
        case failed(String)
    }

    @discardableResult
    func generate(model: InstalledModel, request: GenerationRequest, previewEvery: Int) async -> Outcome {
        await acquireWork()
        defer { releaseWork() }
        let outcome: Outcome
        lastError = nil
        preview = nil
        etaSeconds = nil
        cancelFlag.set(false)

        do {
            let backend = try await prepareBackend(for: model, request: request)
            // Record the speed settings this run applies (they follow the current Settings, not
            // what a restored picture used), so the saved settings describe this picture.
            let request = backend.withSpeedSettings(request)
            phase = .generating(step: 0, total: request.steps)
            let start = Date()
            let flag = cancelFlag
            let timer = StepTimer()
            let image: CGImage? = try await run {
                try backend.generate(request, previewEvery: previewEvery) { step, total, preview in
                    let eta = timer.record(step: step, total: total)
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy else { return }
                        self.phase = .generating(step: step, total: total)
                        self.etaSeconds = eta
                        if let preview { self.preview = preview }
                    }
                    return !flag.isSet
                }
            }
            guard let image else { throw BackendError.noImage }
            let seconds = Date().timeIntervalSince(start)
            lastImage = image
            preview = nil
            let record = try ImageSaver.save(image, request: request, model: model, seconds: seconds)
            lastRecord = record
            outcome = .saved(record)
        } catch is CancellationError {
            preview = nil
            outcome = .cancelled
        } catch {
            lastError = error.localizedDescription
            outcome = .failed(error.localizedDescription)
        }
        phase = .idle
        etaSeconds = nil
        return outcome
    }

    private func prepareBackend(for model: InstalledModel, request: GenerationRequest) async throws -> ImageBackend {
        if let backend, backend.model == model, loadedModelID == model.id {
            if backend.needsReload(for: request) {
                phase = .loading(model.name)
                try await run { try backend.load(for: request) }
            }
            return backend
        }
        phase = .loading(model.name)
        let previous = backend
        backend = nil
        loadedModelID = nil
        let next = try Backends.make(for: model)
        try await run {
            previous?.unload()
            try next.load(for: request)
        }
        backend = next
        loadedModelID = model.id
        return next
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

/// Seconds-per-step from the steps seen so far. The first step is skipped as a baseline
/// because it also includes text encoding and warm-up.
private final class StepTimer: @unchecked Sendable {
    private var first: (step: Int, time: Date)?

    func record(step: Int, total: Int) -> Double? {
        let now = Date()
        guard let first else {
            self.first = (step, now)
            return nil
        }
        let done = step - first.step
        guard done > 0 else { return nil }
        let perStep = now.timeIntervalSince(first.time) / Double(done)
        return perStep * Double(max(total - step, 0))
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
