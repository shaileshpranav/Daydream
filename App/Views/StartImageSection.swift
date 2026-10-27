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
                        Text("How much to change it")
                        Slider(value: Binding(get: { app.request.change ?? 0.6 }, set: { app.request.change = $0 }),
                               in: 0.05...1, step: 0.05) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("A little").font(.caption2)
                        } maximumValueLabel: {
                            Text("A lot").font(.caption2)
                        }
                        .help("Change: \((app.request.change ?? 0.6).formatted(.number.precision(.fractionLength(2))))")
                        Text(changeHint).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Choose Another…") { picking = true }
                    Spacer()
                    Button("Don't Use a Picture", role: .destructive) { app.request.startImage = nil }
                }
                .task(id: path) {
                    thumbnail = await Task.detached { StartImages.load(path).flatMap { thumb($0) } }.value
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.plus").font(.title2).foregroundStyle(.secondary)
                    Text("Optional: drag a photo here to change it with your description, or")
                        .multilineTextAlignment(.center)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Choose a Picture…") { picking = true }
                }
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : .secondary.opacity(0.5)))
            }
        } header: {
            Text("Start from a picture")
        } footer: {
            if app.request.startImage != nil, let model, model.kind.hasFixedSize {
                Text("\(model.name) makes square pictures, so the edges of a non-square picture are trimmed.")
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
        case ..<0.3: "Light touch: keeps the layout and most details"
        case ..<0.7: "Keeps the layout, redraws details to match your description"
        default: "Big changes: mostly follows your description, the picture is a rough guide"
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
