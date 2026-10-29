import SwiftUI
import UniformTypeIdentifiers

enum EditTool: String, CaseIterable, Identifiable {
    case adjust = "Adjust"
    case crop = "Crop"
    case words = "Words"
    case paint = "Paint"
    case background = "Background"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .crop: "crop.rotate"
        case .words: "text.bubble"
        case .paint: "paintbrush"
        case .background: "person.crop.rectangle"
        }
    }

    var help: String {
        switch self {
        case .adjust: "Exposure, contrast, saturation and warmth"
        case .crop: "Crop, rotate and flip"
        case .words: "Edit with words: describe a change and an editing model redraws the picture"
        case .paint: "Paint to redraw: brush over a part and redraw only that part"
        case .background: "Remove the background, keeping the subject"
        }
    }
}

/// The Edit section: one picture, a stack of steps, and the tools that add them.
struct EditView: View {
    @Environment(AppState.self) private var app
    @State private var confirmDiscard = false

    var body: some View {
        Group {
            if let session = app.editSession {
                EditWorkspace(session: session)
                    .id(ObjectIdentifier(session))
            } else {
                EditWelcome()
            }
        }
        .navigationTitle("Edit")
        // Opening another picture while this one has unsaved steps asks first.
        .onChange(of: app.editRequest, initial: true) { openRequested() }
        .confirmationDialog("Discard your edits to \(app.editSession?.name ?? "this picture")?",
                            isPresented: $confirmDiscard) {
            Button("Save and Open the New Picture") {
                Task {
                    try? await app.editSession?.save()
                    await openPending()
                }
            }
            Button("Discard Edits", role: .destructive) { Task { await openPending() } }
            Button("Cancel", role: .cancel) { app.editRequest = nil }
        } message: {
            Text("Its steps haven't been saved to My Pictures.")
        }
    }

    private func openRequested() {
        guard app.editRequest != nil else { return }
        if let session = app.editSession, session.hasChanges, session.saved == nil {
            confirmDiscard = true
        } else {
            Task { await openPending() }
        }
    }

    private func openPending() async {
        guard let request = app.editRequest else { return }
        app.editRequest = nil
        do {
            let session: EditSession
            switch request {
            case .record(let record): session = try await EditSession.open(record)
            case .file(let url): session = try await EditSession.open(file: url)
            }
            app.editError = nil
            app.editSession?.close()
            app.editSession = session
        } catch {
            app.editError = error.localizedDescription
        }
    }
}

// MARK: - Welcome

/// Shown with no picture open: recent pictures to pick from, or a file.
private struct EditWelcome: View {
    @Environment(AppState.self) private var app
    @State private var records: [GenerationRecord] = []
    @State private var importing = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar {
                Text("Edit").font(.headline)
                Spacer()
                Button("Open File…", systemImage: "folder") { importing = true }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 18) {
                    ContentUnavailableView {
                        Label("Open a picture to edit", systemImage: "paintbrush.pointed")
                    } description: {
                        Text("Adjust and crop, edit with words, paint over a part to redraw it, or remove the background. Each step can be undone, and nothing reaches My Pictures until you save.")
                    }
                    if let error = app.editError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent pictures").font(.headline)
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(records.prefix(24)) { record in
                                    Button { app.openEditor(record) } label: { Thumbnail(record: record) }
                                        .buttonStyle(.plain)
                                        .help(record.request.prompt)
                                }
                            }
                        }
                        .frame(maxWidth: 900)
                    }
                }
                .padding(24)
            }
        }
        .task { records = await ImageSaver.loadRecords() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { app.openEditor(file: url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            app.openEditor(file: url)
            return true
        }
    }
}

private struct Thumbnail: View {
    let record: GenerationRecord
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: record.fileName) {
            let record = record
            image = await Task.detached { ImageSaver.thumbnail(for: record, maxPixels: 256) }.value
        }
    }
}

// MARK: - Workspace

private struct EditWorkspace: View {
    @Environment(AppState.self) private var app
    @Environment(Generator.self) private var generator
    @Environment(ModelStore.self) private var store
    @AppStorage(GenerationQueue.previewEveryKey) private var previewEvery = 5
    @AppStorage("edit.tool") private var tool = EditTool.adjust
    let session: EditSession

    // Drafts for the tools that preview live before Apply.
    @State private var adjustments = Adjustments()
    @State private var crop = CropSettings()
    @State private var cropAspect: CropAspect = .free
    @State private var strokes: [BrushStroke] = []
    @State private var brushSize = 40.0
    @State private var erasing = false
    @State private var wordsPrompt = ""
    @State private var wordsModelID: String?
    @State private var references: [URL] = []
    @State private var paintPrompt = ""
    @State private var paintModelID: String?
    @State private var paintChange = 0.85

    /// The current picture scaled down for fast live previews.
    @State private var proxy: CGImage?
    @State private var draft: CGImage?
    @State private var comparing = false
    @State private var confirmClose = false
    @State private var savedMessage: String?

    private var editingModels: [InstalledModel] { store.installed.filter(\.supportsEditing) }
    private var paintingModels: [InstalledModel] { store.installed.filter(\.supportsStartImage) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let busy = session.busy {
                progressBar(busy)
            }
            HStack(spacing: 0) {
                toolPanel
                    .frame(width: 300)
                    .background(Theme.panel)
                Divider()
                EditCanvas(image: shownImage, tool: comparing ? nil : tool, crop: $crop, cropAspect: cropAspect,
                           strokes: $strokes, brushSize: brushSize, erasing: erasing,
                           fullSize: CGSize(width: session.current.width, height: session.current.height),
                           preview: session.isBusy ? generator.preview : nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HistoryPanel(session: session)
                    .frame(width: 230)
                    .background(Theme.panel)
            }
        }
        .task(id: session.position) { await makeProxy() }
        .task(id: draftKey) { await makeDraft() }
        .onAppear { pickModels() }
        .onChange(of: store.installed.count) { pickModels() }
        .confirmationDialog("Close \(session.name) without saving?", isPresented: $confirmClose) {
            Button("Save and Close") {
                Task {
                    try? await session.save()
                    closeSession()
                }
            }
            Button("Close Without Saving", role: .destructive) { closeSession() }
        } message: {
            Text("Its steps haven't been saved to My Pictures.")
        }
    }

    // MARK: Header

    private var header: some View {
        HeaderBar {
            Text(session.name).font(.headline).lineLimit(1)
            if let savedMessage {
                Text(savedMessage).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                Button("Undo", systemImage: "arrow.uturn.backward") { session.undo(); resetDrafts() }
                    .disabled(!session.canUndo)
                    .help("Undo the last step")
                Button("Redo", systemImage: "arrow.uturn.forward") { session.redo(); resetDrafts() }
                    .disabled(!session.canRedo)
                    .help("Redo the step you undid")
                Button("Compare", systemImage: "square.split.2x1") { comparing.toggle() }
                    .buttonStyle(IconButtonStyle(isSelected: comparing))
                    .help(comparing ? "Showing the original: click to go back" : "Show the original")
                    .disabled(!session.hasChanges)
            }
            .buttonStyle(IconButtonStyle())
            Divider().frame(height: 18)
            Button("Close") {
                if session.hasChanges && session.saved == nil { confirmClose = true } else { closeSession() }
            }
            .controlSize(.small)
            .disabled(session.isBusy)
            Button("Save to My Pictures") { save() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!session.hasChanges || session.isBusy)
                .help("Save the edited picture as a new picture (⌘S); the original stays as it is")
        }
    }

    private func progressBar(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.caption)
            if case .generating(let step, let total) = generator.phase {
                ProgressView(value: Double(step), total: Double(max(total, 1))).frame(width: 140)
                Text("step \(step) of \(total)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if case .loading(let name) = generator.phase {
                Text("loading \(name)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if generator.isBusy {
                Button("Stop") { generator.cancel() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.raised)
    }

    // MARK: Tools

    private var toolPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(EditTool.allCases) { item in
                    Button(item.rawValue, systemImage: item.icon) {
                        tool = item
                        resetDrafts()
                    }
                    .buttonStyle(IconButtonStyle(isSelected: tool == item, size: 36))
                    .help(item.help)
                }
            }
            .padding(8)
            Divider()
            Form {
                switch tool {
                case .adjust: adjustTool
                case .crop: cropTool
                case .words: wordsTool
                case .paint: paintTool
                case .background: backgroundTool
                }
                if let error = session.error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(session.isBusy)
        }
    }

    @ViewBuilder
    private var adjustTool: some View {
        Section("Adjust") {
            slider("Exposure", value: $adjustments.exposure, range: -2...2)
            slider("Contrast", value: $adjustments.contrast, range: -1...1)
            slider("Saturation", value: $adjustments.saturation, range: -1...1)
            slider("Warmth", value: $adjustments.warmth, range: -1...1)
        }
        Section {
            applyButtons(apply: "Apply Adjustments", disabled: adjustments.isIdentity) {
                let a = adjustments
                Task { await session.apply(.adjust(a), label: "Adjusting…") { try ImageEdits.adjust($0, a) }; resetDrafts() }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: value, in: range)
                .onTapGesture(count: 2) { value.wrappedValue = 0 }
                .help("Double-click to reset")
        }
    }

    @ViewBuilder
    private var cropTool: some View {
        Section("Rotate and flip") {
            HStack {
                Button("Rotate Left", systemImage: "rotate.left") { crop.quarterTurns = (crop.quarterTurns + 3) % 4; crop.rect = CropSettings().rect }
                Button("Rotate Right", systemImage: "rotate.right") { crop.quarterTurns = (crop.quarterTurns + 1) % 4; crop.rect = CropSettings().rect }
                Button("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { crop.flipHorizontal.toggle() }
                Button("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { crop.flipVertical.toggle() }
            }
            .labelStyle(.iconOnly)
        }
        Section("Crop") {
            Picker("Shape", selection: $cropAspect) {
                ForEach(CropAspect.allCases) { Text($0.rawValue).tag($0) }
            }
            .onChange(of: cropAspect) { crop.rect = cropAspect.fit(in: orientedSize) }
            Text("Drag the corners or the middle of the frame on the picture.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            applyButtons(apply: "Apply Crop", disabled: crop.isIdentity) {
                let c = crop
                Task { await session.apply(.crop(c), label: "Cropping…") { try ImageEdits.transform($0, c) }; resetDrafts() }
            }
        }
    }

    /// The current picture's size after the draft rotation.
    private var orientedSize: CGSize {
        let (w, h) = (Double(session.current.width), Double(session.current.height))
        return crop.quarterTurns % 2 == 0 ? CGSize(width: w, height: h) : CGSize(width: h, height: w)
    }

    @ViewBuilder
    private var wordsTool: some View {
        Section("Describe the change") {
            TextField("Change", text: $wordsPrompt, prompt: Text("make it a snowy night, keep everything else"),
                      axis: .vertical)
                .lineLimit(3...6)
            Text("Say what to change and what to keep. Short, concrete instructions work best.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Model") {
            if editingModels.isEmpty {
                Text("Needs an editing model: FLUX.2 Klein or FLUX 3 Klein. Install one on the Models page.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Models") { app.section = .models }
            } else {
                Picker("Model", selection: $wordsModelID) {
                    ForEach(editingModels) { Text($0.name).tag(Optional($0.id)) }
                }
                Text("Redraws the whole picture at the model's size (about 80 s with FLUX.2 Klein 4B at 1024 px here). The first edit reloads the model for editing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Section("More pictures (optional)") {
            ForEach(references, id: \.self) { url in
                HStack {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { references.removeAll { $0 == url } }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
            }
            ReferencePicker(references: $references)
            Text("Pictures to take something from, e.g. a hat or a style: “put the hat from the second picture on him”.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("Edit Picture") {
                guard let model = store.model(id: wordsModelID) else { return }
                let (prompt, refs) = (wordsPrompt.trimmingCharacters(in: .whitespacesAndNewlines), references)
                Task {
                    await session.editWithWords(prompt, references: refs, model: model, generator: generator,
                                                previewEvery: previewEvery)
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(wordsPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.model(id: wordsModelID) == nil)
        }
    }

    @ViewBuilder
    private var paintTool: some View {
        Section("Brush") {
            Picker("Mode", selection: $erasing) {
                Label("Paint", systemImage: "paintbrush").tag(false)
                Label("Erase", systemImage: "eraser").tag(true)
            }
            .pickerStyle(.segmented)
            slider("Size", value: $brushSize, range: 5...150)
            Button("Clear the Painted Area") { strokes.removeAll() }
                .disabled(strokes.isEmpty)
        }
        Section("What to draw there") {
            TextField("Prompt", text: $paintPrompt, prompt: Text("a red wool scarf"), axis: .vertical)
                .lineLimit(2...4)
            slider("How much to change", value: $paintChange, range: 0.3...1)
            Text("Lower keeps more of what's under the brush; 1 draws it fresh.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Model") {
            Picker("Model", selection: $paintModelID) {
                ForEach(paintingModels) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("The painted area and some of its surroundings are redrawn at the model's full size, then blended back with a soft edge. Outside the brush nothing changes.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            Button("Redraw Painted Area") {
                guard let model = store.model(id: paintModelID) else { return }
                let (prompt, painted, change) = (paintPrompt.trimmingCharacters(in: .whitespacesAndNewlines), strokes, paintChange)
                Task {
                    await session.paint(prompt, strokes: painted, change: change, model: model, generator: generator,
                                        previewEvery: previewEvery)
                    if session.error == nil { strokes.removeAll() }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
            .disabled(strokes.isEmpty || paintPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || store.model(id: paintModelID) == nil)
        }
    }

    @ViewBuilder
    private var backgroundTool: some View {
        Section("Remove background") {
            Text("Keeps the main subject (people, animals, objects) and makes the rest transparent, with macOS's built-in Vision model. Saved pictures keep the transparency.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Remove Background") {
                Task { await session.apply(.removeBackground, label: "Finding the subject…") { try ImageEdits.removeBackground($0) } }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
        }
    }

    private func applyButtons(apply: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Button("Reset") { resetDrafts() }.disabled(disabled)
            Spacer()
            Button(apply, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
    }

    // MARK: Drafts and previews

    /// What the canvas shows: the original while comparing, else a live draft, else the picture.
    private var shownImage: CGImage {
        if comparing { return session.original }
        return draft ?? proxy ?? session.current
    }

    private var draftKey: String {
        "\(session.position)|\(tool.rawValue)|\(adjustments.hashValue)|\(crop.quarterTurns)|\(crop.flipHorizontal)|\(crop.flipVertical)"
    }

    private func makeProxy() async {
        let current = session.current
        proxy = await Task.detached { try? ImageEdits.limited(current, maxSide: 1400) }.value
    }

    private func makeDraft() async {
        try? await Task.sleep(for: .milliseconds(30))  // let slider drags settle
        guard !Task.isCancelled, let base = proxy ?? Optional(session.current) else { return }
        switch tool {
        case .adjust where !adjustments.isIdentity:
            let a = adjustments
            draft = await Task.detached { try? ImageEdits.adjust(base, a) }.value
        case .crop where crop.quarterTurns != 0 || crop.flipHorizontal || crop.flipVertical:
            // The frame is drawn over the rotated picture; the crop itself happens on Apply.
            var turned = crop
            turned.rect = CropSettings().rect
            draft = await Task.detached { [turned] in try? ImageEdits.transform(base, turned) }.value
        default:
            draft = nil
        }
    }

    private func resetDrafts() {
        adjustments = Adjustments()
        crop = CropSettings()
        cropAspect = .free
        draft = nil
    }

    private func pickModels() {
        if store.model(id: wordsModelID)?.supportsEditing != true {
            wordsModelID = (editingModels.first { $0.id == app.selectedModelID } ?? editingModels.first)?.id
        }
        if store.model(id: paintModelID)?.supportsStartImage != true {
            paintModelID = (paintingModels.first { $0.id == app.selectedModelID } ?? paintingModels.first)?.id
        }
    }

    private func save() {
        Task {
            do {
                let record = try await session.save()
                savedMessage = "Saved as \(record.fileName)"
            } catch {
                session.error = error.localizedDescription
            }
        }
    }

    private func closeSession() {
        session.close()
        app.editSession = nil
    }
}

/// Adds pictures for Edit with words: from a file, or by dropping them on the row.
private struct ReferencePicker: View {
    @Binding var references: [URL]
    @State private var importing = false

    var body: some View {
        Button("Add Picture…", systemImage: "plus") { importing = true }
            .disabled(references.count >= 3)
            .fileImporter(isPresented: $importing, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { references = Array((references + urls).prefix(3)) }
            }
            .dropDestination(for: URL.self) { urls, _ in
                references = Array((references + urls).prefix(3))
                return true
            }
    }
}

/// Crop frame shapes, as width ÷ height.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Free"
    case square = "Square"
    case landscape = "4:3"
    case portrait = "3:4"
    case wide = "16:9"
    case tall = "9:16"

    var id: String { rawValue }

    var ratio: Double? {
        switch self {
        case .free: nil
        case .square: 1
        case .landscape: 4.0 / 3
        case .portrait: 3.0 / 4
        case .wide: 16.0 / 9
        case .tall: 9.0 / 16
        }
    }

    /// The largest centred frame of this shape in a picture of `size`, in 0–1 units.
    func fit(in size: CGSize) -> CGRect {
        guard let ratio, size.width > 0, size.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let pictureRatio = size.width / size.height
        let (w, h) = ratio > pictureRatio ? (1.0, pictureRatio / ratio) : (ratio / pictureRatio, 1.0)
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}

// MARK: - History

private struct HistoryPanel: View {
    let session: EditSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History").font(.headline).padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(icon: "photo", title: "Original", detail: "\(session.original.width) × \(session.original.height)", index: 0)
                    ForEach(Array(session.steps.enumerated()), id: \.element.id) { i, step in
                        row(icon: step.operation.icon, title: step.operation.title,
                            detail: step.operation.detail + " · \(step.seconds.formatted(.number.precision(.fractionLength(1)))) s",
                            index: i + 1)
                    }
                }
                .padding(8)
            }
            Divider()
            Text("Click a step to go back to it. A new step replaces the ones after it.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(12)
        }
    }

    private func row(icon: String, title: String, detail: String, index: Int) -> some View {
        let isCurrent = index == session.position
        let isUndone = index > session.position
        return Button { session.show(index) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(isCurrent ? Theme.accent : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(isCurrent ? .semibold : .regular))
                    if !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Theme.accent.opacity(0.15) : .clear))
            .opacity(isUndone ? 0.45 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isBusy)
    }
}

// MARK: - Canvas

/// The picture, fitted to the space, with the crop frame or the brush drawn over it.
private struct EditCanvas: View {
    let image: CGImage
    /// Nil while comparing: no overlays.
    let tool: EditTool?
    @Binding var crop: CropSettings
    let cropAspect: CropAspect
    @Binding var strokes: [BrushStroke]
    let brushSize: Double
    let erasing: Bool
    /// The full-size picture's pixels, which strokes are measured in.
    let fullSize: CGSize
    /// A live preview from the model while a step runs.
    let preview: CGImage?

    @State private var hover: CGPoint?
    @State private var dragStart: (rect: CGRect, point: CGPoint, handle: Handle)?
    /// True from a brush drag's first point to its last, so its points join one stroke.
    @State private var painting = false

    private enum Handle { case move, topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        GeometryReader { geo in
            let frame = fitted(CGSize(width: image.width, height: image.height), in: geo.size.insetBy(24))
            ZStack(alignment: .topLeading) {
                Checkerboard()
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
                if tool == .crop { cropOverlay(frame) }
                if tool == .paint { paintOverlay(frame) }
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
                        .overlay(alignment: .bottomLeading) {
                            Text("Preview").font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(6)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .background(Theme.base)
    }

    private func fitted(_ size: CGSize, in space: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, space.width > 0, space.height > 0 else { return .zero }
        let scale = min(space.width / size.width, space.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: 24 + (space.width - w) / 2, y: 24 + (space.height - h) / 2, width: w, height: h)
    }

    // MARK: Crop

    private func cropOverlay(_ frame: CGRect) -> some View {
        let r = crop.rect
        let box = CGRect(x: frame.minX + r.minX * frame.width, y: frame.minY + r.minY * frame.height,
                         width: r.width * frame.width, height: r.height * frame.height)
        return ZStack(alignment: .topLeading) {
            // Darken outside the frame.
            Path { p in
                p.addRect(frame)
                p.addRect(box)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                           CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)]
            ForEach(corners.indices, id: \.self) { i in
                Circle().fill(Color.white).frame(width: 12, height: 12)
                    .offset(x: corners[i].x - 6, y: corners[i].y - 6)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1).onChanged { value in
            dragCrop(value, frame: frame, box: box)
        }.onEnded { _ in dragStart = nil })
    }

    private func dragCrop(_ value: DragGesture.Value, frame: CGRect, box: CGRect) {
        if dragStart == nil {
            let p = value.startLocation
            let corners: [(Handle, CGPoint)] = [(.topLeft, CGPoint(x: box.minX, y: box.minY)), (.topRight, CGPoint(x: box.maxX, y: box.minY)),
                                                (.bottomLeft, CGPoint(x: box.minX, y: box.maxY)), (.bottomRight, CGPoint(x: box.maxX, y: box.maxY))]
            let near = corners.first { hypot($0.1.x - p.x, $0.1.y - p.y) < 18 }?.0
            dragStart = (crop.rect, p, near ?? .move)
        }
        guard let start = dragStart, frame.width > 0, frame.height > 0 else { return }
        let dx = (value.location.x - start.point.x) / frame.width
        let dy = (value.location.y - start.point.y) / frame.height
        var r = start.rect
        switch start.handle {
        case .move:
            r.origin.x = min(max(r.minX + dx, 0), 1 - r.width)
            r.origin.y = min(max(r.minY + dy, 0), 1 - r.height)
        case .topLeft: r = CGRect(x: r.minX + dx, y: r.minY + dy, width: r.width - dx, height: r.height - dy)
        case .topRight: r = CGRect(x: r.minX, y: r.minY + dy, width: r.width + dx, height: r.height - dy)
        case .bottomLeft: r = CGRect(x: r.minX + dx, y: r.minY, width: r.width - dx, height: r.height + dy)
        case .bottomRight: r = CGRect(x: r.minX, y: r.minY, width: r.width + dx, height: r.height + dy)
        }
        r = r.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // A fixed shape keeps its width ÷ height in pixels, anchored at the corner opposite the drag.
        if let ratio = cropAspect.ratio, start.handle != .move {
            let pictureRatio = frame.width / frame.height
            let h = min(r.width * pictureRatio / ratio, 1)
            let w = h * ratio / pictureRatio
            let anchorBottom = start.handle == .topLeft || start.handle == .topRight
            let anchorRight = start.handle == .topLeft || start.handle == .bottomLeft
            r = CGRect(x: anchorRight ? start.rect.maxX - w : start.rect.minX,
                       y: anchorBottom ? start.rect.maxY - h : start.rect.minY, width: w, height: h)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        if r.width > 0.03, r.height > 0.03 { crop.rect = r }
    }

    // MARK: Paint

    private func paintOverlay(_ frame: CGRect) -> some View {
        let scale = frame.width / max(fullSize.width, 1)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Painted strokes in translucent red; eraser strokes cut them back out.
                context.drawLayer { layer in
                    for stroke in strokes {
                        var path = Path()
                        let points = stroke.points.map { CGPoint(x: frame.minX + $0.x * scale, y: frame.minY + $0.y * scale) }
                        if points.count == 1, let p = points.first {
                            let r = stroke.radius * scale
                            path.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                            layer.blendMode = stroke.erases ? .clear : .normal
                            layer.fill(path, with: .color(.red))
                        } else {
                            path.addLines(points)
                            layer.blendMode = stroke.erases ? .clear : .normal
                            layer.stroke(path, with: .color(.red),
                                         style: StrokeStyle(lineWidth: 2 * stroke.radius * scale, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
            }
            .opacity(0.45)
            .allowsHitTesting(false)
            if let hover {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1)
                    .frame(width: brushSize * 2, height: brushSize * 2)
                    .offset(x: hover.x - brushSize, y: hover.y - brushSize)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hover = p } else { hover = nil }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            guard frame.width > 0 else { return }
            hover = value.location
            // Screen points to the full-size picture's pixels.
            let point = CGPoint(x: (value.location.x - frame.minX) / scale, y: (value.location.y - frame.minY) / scale)
            if !painting || strokes.isEmpty {
                painting = true
                strokes.append(BrushStroke(points: [point], radius: brushSize / scale, erases: erasing))
            } else {
                strokes[strokes.count - 1].points.append(point)
            }
        }.onEnded { _ in painting = false })
    }
}

private extension CGSize {
    func insetBy(_ inset: CGFloat) -> CGSize {
        CGSize(width: max(width - 2 * inset, 0), height: max(height - 2 * inset, 0))
    }
}

/// Grey and white squares behind a transparent picture.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let side: CGFloat = 10
            for row in 0..<Int(size.height / side) + 1 {
                for col in 0..<Int(size.width / side) + 1 where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * side, y: CGFloat(row) * side, width: side, height: side)),
                                 with: .color(.gray.opacity(0.35)))
                }
            }
        }
        .background(Color.white.opacity(0.85))
    }
}
