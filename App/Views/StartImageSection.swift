import SwiftUI
import UniformTypeIdentifiers

/// Image-to-image: an optional start image and how much to change it.
struct StartImageSection: View {
    @Environment(AppState.self) private var app
    let model: InstalledModel?
    @State private var picking = false
    @State private var thumbnail: CGImage?
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var app = app
        Section {
            if let path = app.request.startImage {
                HStack(alignment: .top, spacing: 10) {
                    Group {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Change: \(app.request.change ?? 0.6, specifier: "%.2f")")
                        Slider(value: Binding(get: { app.request.change ?? 0.6 }, set: { app.request.change = $0 }),
                               in: 0.05...1, step: 0.05)
                        Text(changeHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Replace…") { picking = true }
                    Spacer()
                    Button("Remove", role: .destructive) { app.request.startImage = nil }
                }
                .task(id: path) {
                    thumbnail = await Task.detached { StartImages.load(path).flatMap { thumb($0) } }.value
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text("Drop an image here, or")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose Image…") { picking = true }
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5)))
            }
        } header: {
            Text("Start Image")
        } footer: {
            if app.request.startImage != nil, let model, model.kind.hasFixedSize {
                Text("\(model.name) works at \(model.resolution)×\(model.resolution); the start image is scaled and centre-cropped to fit.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            use(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { use(url) }
        }
    }

    private var changeHint: String {
        switch app.request.change ?? 0.6 {
        case ..<0.3: "Light touch: keeps the composition and most details"
        case ..<0.7: "Keeps the composition, redraws details to match the prompt"
        default: "Loose: mostly follows the prompt, the image is a rough guide"
        }
    }

    private func use(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        app.useAsStartImage(url, for: model)
    }
}

private func thumb(_ image: CGImage) -> CGImage? {
    let scale = 144.0 / Double(max(image.width, image.height))
    return StartImages.fill(image, width: max(1, Int(Double(image.width) * scale)),
                            height: max(1, Int(Double(image.height) * scale)))
}
