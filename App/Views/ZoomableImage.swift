import SwiftUI

/// How far an image is zoomed. Shared between a `ZoomableImage` and the buttons that drive it.
@MainActor
@Observable
final class ZoomState {
    /// nil = fit to the view; otherwise pixels per image pixel (1 = actual size).
    var zoom: CGFloat?
    /// The scale "fit" works out to for the current image and view size, so zooming
    /// starts from what's on screen rather than from actual size.
    fileprivate(set) var fitScale: CGFloat = 1

    static let range: ClosedRange<CGFloat> = 0.1...8

    var scale: CGFloat { zoom ?? fitScale }
    var isFit: Bool { zoom == nil }

    func fit() { zoom = nil }
    func actualSize() { zoom = 1 }
    func zoomIn() { zoom = min(scale * 1.5, Self.range.upperBound) }
    func zoomOut() { zoom = max(scale / 1.5, Self.range.lowerBound) }
    func toggleFitAndActual() { zoom = zoom == nil ? 1 : nil }
}

/// An image that fits its space, or zooms: pinch, double-click (fit ⇄ actual size), or the
/// buttons bound to the same `ZoomState`. Scroll to move around a zoomed image.
struct ZoomableImage: View {
    let image: CGImage?
    let state: ZoomState
    /// Space around the image when it's fitted.
    var inset: CGFloat = 0
    var cornerRadius: CGFloat = 0
    /// What dragging a fitted image out of the view drops (e.g. the PNG file).
    var dragItem: (() -> NSItemProvider)?

    @State private var pinchStart: CGFloat?
    @State private var areaSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            if let image {
                let size = CGSize(width: image.width, height: image.height)
                if let zoom = state.zoom {
                    ScrollView([.horizontal, .vertical]) {
                        picture(image)
                            .interpolation(zoom >= 2 ? .none : .high)
                            .frame(width: size.width * zoom, height: size.height * zoom)
                            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                            .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                    }
                } else {
                    picture(image)
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .padding(inset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .onDrag { dragItem?() ?? NSItemProvider() }
                }
            }
        }
        .contentShape(Rectangle())
        .gesture(MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? state.scale
                pinchStart = start
                state.zoom = min(max(start * value.magnification, ZoomState.range.lowerBound), ZoomState.range.upperBound)
            }
            .onEnded { _ in pinchStart = nil })
        .onTapGesture(count: 2) { state.toggleFitAndActual() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            areaSize = $0
            updateFitScale()
        }
        .onChange(of: image.map { CGSize(width: $0.width, height: $0.height) }) { updateFitScale() }
        .onAppear(perform: updateFitScale)
        .help("Double-click to switch between fit and actual size; pinch to zoom")
    }

    private func picture(_ image: CGImage) -> Image {
        Image(decorative: image, scale: 1).resizable()
    }

    private func updateFitScale() {
        guard let image, image.width > 0, image.height > 0, areaSize.width > 0 else { return }
        state.fitScale = min((areaSize.width - 2 * inset) / CGFloat(image.width),
                             (areaSize.height - 2 * inset) / CGFloat(image.height))
    }
}

/// Fit, actual size, zoom out, the current zoom, zoom in, with ⌘0, ⌘1, ⌘− and ⌘+.
/// `compact` is a small floating pill: −, the zoom (click it for fit ⇄ actual size), +.
struct ZoomControls: View {
    let state: ZoomState
    var compact = false

    var body: some View {
        if compact {
            HStack(spacing: 0) {
                Button("Zoom Out", systemImage: "minus") { state.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(state.scale <= ZoomState.range.lowerBound)
                    .help("Zoom out (⌘−)")
                Button(state.isFit ? "Fit" : "\(Int((state.scale * 100).rounded()))%") { state.toggleFitAndActual() }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .frame(minWidth: 44)
                    .help(state.isFit ? "Fitted to the window. Click for actual size (⌘1)" : "Click to fit (⌘0)")
                Button("Zoom In", systemImage: "plus") { state.zoomIn() }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(state.scale >= ZoomState.range.upperBound)
                    .help("Zoom in (⌘+)")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .background {
                // Keyboard-only: ⌘0 and ⌘1 without taking room in the pill.
                Group {
                    Button("Fit") { state.fit() }.keyboardShortcut("0", modifiers: .command)
                    Button("Actual Size") { state.actualSize() }.keyboardShortcut("1", modifiers: .command)
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
        } else {
            full
        }
    }

    private var full: some View {
        Group {
            Button("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { state.fit() }
                .keyboardShortcut("0", modifiers: .command)
                .help("Fit (⌘0)")
            Button("Actual Size", systemImage: "1.magnifyingglass") { state.actualSize() }
                .keyboardShortcut("1", modifiers: .command)
                .help("Actual size (⌘1)")
            Button("Zoom Out", systemImage: "minus.magnifyingglass") { state.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(state.scale <= ZoomState.range.lowerBound)
                .help("Zoom out (⌘−)")
            Text(state.isFit ? "Fit" : "\(Int((state.scale * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38)
            Button("Zoom In", systemImage: "plus.magnifyingglass") { state.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(state.scale >= ZoomState.range.upperBound)
                .help("Zoom in (⌘+)")
        }
        .buttonStyle(IconButtonStyle())
    }
}
