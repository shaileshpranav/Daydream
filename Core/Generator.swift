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
    var lastError: String?

    var isBusy: Bool { phase != .idle }

    private var backend: ImageBackend?
    private let queue = DispatchQueue(label: "CoreMLImageGen.inference", qos: .userInitiated)
    private let cancelFlag = CancelFlag()

    func cancel() {
        cancelFlag.set(true)
    }

    /// Frees the resident model, e.g. before a large download or when switching.
    func unloadModel() {
        guard !isBusy, let backend else { return }
        queue.async { backend.unload() }
        self.backend = nil
        loadedModelID = nil
    }

    enum Outcome: Equatable {
        case saved(GenerationRecord)
        case cancelled
        case failed(String)
    }

    @discardableResult
    func generate(model: InstalledModel, request: GenerationRequest, previewEvery: Int) async -> Outcome {
        guard !isBusy else { return .failed("Another image is already generating.") }
        let outcome: Outcome
        lastError = nil
        preview = nil
        cancelFlag.set(false)

        do {
            let backend = try await prepareBackend(for: model, request: request)
            phase = .generating(step: 0, total: request.steps)
            let start = Date()
            let flag = cancelFlag
            let image: CGImage? = try await run {
                try backend.generate(request, previewEvery: previewEvery) { step, total, preview in
                    Task { @MainActor [weak self] in
                        guard let self, self.isBusy else { return }
                        self.phase = .generating(step: step, total: total)
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

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
