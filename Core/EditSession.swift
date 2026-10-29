import CoreGraphics
import Foundation
import Observation

/// One step in the Edit section's history.
enum EditOperation: Codable, Hashable {
    case adjust(Adjustments)
    case crop(CropSettings)
    case removeBackground
    case words(prompt: String, model: String, references: Int)
    case paint(prompt: String, model: String, change: Double)

    var title: String {
        switch self {
        case .adjust: "Adjust"
        case .crop: "Crop & Rotate"
        case .removeBackground: "Remove Background"
        case .words: "Edit with Words"
        case .paint: "Paint to Redraw"
        }
    }

    var detail: String {
        switch self {
        case .adjust(let a): a.summary
        case .crop(let c): c.summary
        case .removeBackground: "Subject kept, background transparent"
        case .words(let prompt, let model, let references):
            "“\(prompt)”, \(model)" + (references > 0 ? ", \(references) more picture\(references == 1 ? "" : "s")" : "")
        case .paint(let prompt, let model, let change):
            "“\(prompt)”, \(model), change \(change.formatted(.number.precision(.fractionLength(2))))"
        }
    }

    /// For the saved picture's record.
    var summary: String { detail.isEmpty ? title : "\(title): \(detail)" }

    var icon: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .crop: "crop.rotate"
        case .removeBackground: "person.crop.rectangle"
        case .words: "text.bubble"
        case .paint: "paintbrush"
        }
    }
}

struct EditStep: Identifiable {
    let id = UUID()
    let operation: EditOperation
    /// The picture after this step, in the session's folder.
    let file: URL
    let seconds: Double
}

/// A picture open in the Edit section and the steps applied to it. Each step's result is kept
/// as a PNG in a temporary folder, so undo, redo and jumping around the history are instant
/// and only the current picture stays in memory. Nothing reaches My Pictures until Save.
@MainActor
@Observable
final class EditSession {
    nonisolated static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "CoreMLImageGen/Edits", directoryHint: .isDirectory)

    /// The picture in My Pictures this started from; nil for a file opened from disk.
    let source: GenerationRecord?
    /// Shown in the header and used to name the saved file.
    let name: String
    let original: CGImage
    private let folder: URL

    private(set) var steps: [EditStep] = []
    /// How many of `steps` are in effect; undo moves it back, redo forward.
    private(set) var position = 0
    private(set) var current: CGImage
    /// What's running, for the progress line; nil when idle.
    private(set) var busy: String?
    var error: String?
    /// The last picture saved from this session, if any.
    private(set) var saved: GenerationRecord?

    init(image: CGImage, source: GenerationRecord?, name: String) {
        self.source = source
        self.name = name
        original = image
        current = image
        folder = Self.root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func open(_ record: GenerationRecord) async throws -> EditSession {
        let path = ImageSaver.folder.appending(path: record.fileName).path
        guard let image = await Task.detached(operation: { StartImages.load(path) }).value else {
            throw RuntimeError("\(record.fileName) couldn't be read.")
        }
        return EditSession(image: image, source: record, name: (record.fileName as NSString).deletingPathExtension)
    }

    static func open(file url: URL) async throws -> EditSession {
        let path = url.path
        guard let image = await Task.detached(operation: { StartImages.load(path) }).value else {
            throw RuntimeError("\(url.lastPathComponent) isn't a picture this Mac can read.")
        }
        return EditSession(image: image, source: nil, name: url.deletingPathExtension().lastPathComponent)
    }

    var isBusy: Bool { busy != nil }
    var canUndo: Bool { position > 0 && !isBusy }
    var canRedo: Bool { position < steps.count && !isBusy }
    var hasChanges: Bool { position > 0 }
    var applied: ArraySlice<EditStep> { steps[..<position] }

    func undo() { show(position - 1) }
    func redo() { show(position + 1) }

    /// Goes to the picture after `count` steps (0 is the original). Later steps stay
    /// available for redo until a new step replaces them.
    func show(_ count: Int) {
        guard (0...steps.count).contains(count), !isBusy else { return }
        position = count
        if count == 0 {
            current = original
        } else if let image = StartImages.load(steps[count - 1].file.path) {
            current = image
        }
    }

    // MARK: Steps

    /// Runs `work` on the current picture off the main thread and adds its result as a step.
    func apply(_ operation: EditOperation, label: String, _ work: @escaping @Sendable (CGImage) throws -> CGImage) async {
        let input = current
        await run(operation, label: label) {
            try await Task.detached(priority: .userInitiated) { try work(input) }.value
        }
    }

    /// Edit with words: the model redraws the whole picture following `prompt`, with any
    /// `references` as more pictures to draw from ("put this hat on her").
    func editWithWords(_ prompt: String, references: [URL], model: InstalledModel, generator: Generator,
                       previewEvery: Int) async {
        let input = current
        let operation = EditOperation.words(prompt: prompt, model: model.name, references: references.count)
        await run(operation, label: "Editing with \(model.name)…") {
            // The edit pipelines encode every reference at its own size: keep them to 1024 px.
            let paths = try await Task.detached(priority: .userInitiated) { () throws -> [String] in
                let base = try ImageEdits.limited(ImageEdits.flattened(input), maxSide: 1024)
                var paths = [try StartImages.save(base)]
                for url in references {
                    guard let image = StartImages.load(url.path) else {
                        throw RuntimeError("\(url.lastPathComponent) isn't a picture this Mac can read.")
                    }
                    paths.append(try StartImages.save(ImageEdits.limited(ImageEdits.flattened(image), maxSide: 1024)))
                }
                return paths
            }.value
            var request = GenerationRequest(prompt: prompt)
            request.negativePrompt = ""
            request.steps = model.recommended.steps
            request.guidance = model.recommended.guidance
            request.randomizeSeed()
            request.loras = []
            request.aspect = StartImages.closestAspect(width: input.width, height: input.height) ?? .square
            request.references = paths
            // The copies are only for this run (an edit step isn't remade from its request).
            defer { for path in paths { try? FileManager.default.removeItem(atPath: path) } }
            return try await generator.render(model: model, request: request, previewEvery: previewEvery)
        }
    }

    /// Paint to redraw: the painted area, with some surroundings for context, is redrawn by
    /// `model` from `prompt` and blended back in. Outside the brush nothing changes.
    func paint(_ prompt: String, strokes: [BrushStroke], change: Double, model: InstalledModel,
               generator: Generator, previewEvery: Int) async {
        let input = current
        let operation = EditOperation.paint(prompt: prompt, model: model.name, change: change)
        await run(operation, label: "Redrawing with \(model.name)…") {
            let square = model.kind.hasFixedSize
            let resolution = model.resolution
            let prepared = try await Task.detached(priority: .userInitiated) {
                () throws -> (mask: CGImage, region: CGRect, start: String, aspect: AspectChoice) in
                guard let mask = ImageEdits.mask(for: strokes, width: input.width, height: input.height),
                      let box = ImageEdits.bounds(of: mask)
                else { throw RuntimeError("Paint over the part of the picture to redraw first.") }
                let size = CGSize(width: input.width, height: input.height)
                let region = ImageEdits.redrawRegion(around: box, in: size, square: square)
                guard let crop = ImageEdits.cropped(try ImageEdits.flattened(input), to: region) else {
                    throw RuntimeError("Couldn't cut out the painted area.")
                }
                // The model draws at its own size; the region is scaled to fit it, so a small
                // painted area gets the model's full detail.
                let aspect = square ? AspectChoice.square
                    : StartImages.closestAspect(width: crop.width, height: crop.height) ?? .square
                let target = aspect.size(base: resolution)
                let start = try ImageEdits.resized(crop, to: CGSize(width: target.width, height: target.height))
                return (mask, region, try StartImages.save(start), aspect)
            }.value
            var request = GenerationRequest(prompt: prompt)
            request.negativePrompt = (model.recommended.supportsNegativePrompt ?? true) ? "blurry, low quality, seam" : ""
            request.steps = model.recommended.steps
            request.guidance = model.recommended.guidance
            request.randomizeSeed()
            request.loras = []
            request.aspect = prepared.aspect
            request.startImage = prepared.start
            request.change = change
            let patch: CGImage
            do {
                defer { try? FileManager.default.removeItem(atPath: prepared.start) }
                patch = try await generator.render(model: model, request: request, previewEvery: previewEvery)
            }
            let box = ImageEdits.bounds(of: prepared.mask) ?? prepared.region
            // A soft edge about 3% of the painted area's size, kept inside the brush.
            let feather = min(max(0.03 * max(box.width, box.height), 4), 24)
            return try await Task.detached(priority: .userInitiated) {
                try ImageEdits.composite(base: input, patch: patch, region: prepared.region, mask: prepared.mask, feather: feather)
            }.value
        }
    }

    private func run(_ operation: EditOperation, label: String, _ work: () async throws -> CGImage) async {
        guard !isBusy else { return }
        busy = label
        error = nil
        defer { busy = nil }
        let start = Date()
        do {
            let image = try await work()
            let file = folder.appending(path: "step-\(UUID().uuidString).png")
            try await Task.detached(priority: .userInitiated) { try StartImages.writePNG(image, to: file) }.value
            // A new step replaces anything that was undone.
            steps.removeSubrange(position...)
            steps.append(EditStep(operation: operation, file: file, seconds: Date().timeIntervalSince(start)))
            position = steps.count
            current = image
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Save

    /// Saves the current picture to My Pictures as a new picture that lists the steps.
    @discardableResult
    func save() async throws -> GenerationRecord {
        let image = current
        let source = source
        let summaries = applied.map(\.operation.summary)
        let seconds = applied.reduce(0) { $0 + $1.seconds }
        // A file opened from disk has no settings of its own: its caption is the last prompt
        // used on it, or its name.
        let lastPrompt = applied.reversed().lazy.compactMap { step -> String? in
            switch step.operation {
            case .words(let prompt, _, _), .paint(let prompt, _, _): prompt
            default: nil
            }
        }.first
        let name = name
        let record = try await Task.detached(priority: .userInitiated) {
            try ImageSaver.saveEdited(image, stem: name) { fileName in
                var record = GenerationRecord(fileName: fileName,
                                              request: source?.request ?? GenerationRequest(prompt: lastPrompt ?? name),
                                              modelID: source?.modelID ?? "edited",
                                              modelName: source?.modelName ?? "Edited picture",
                                              date: Date(), seconds: seconds)
                record.edits = summaries
                record.editedFrom = source?.fileName
                return record
            }
        }.value
        saved = record
        return record
    }

    /// Deletes the session's step pictures.
    func close() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes step folders left by sessions that weren't closed (the app quit mid-edit).
    nonisolated static func removeLeftovers() {
        try? FileManager.default.removeItem(at: root)
    }
}
