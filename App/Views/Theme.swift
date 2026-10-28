import SwiftUI

/// A dark, panel-based look inspired by InvokeAI: a near-black base, slightly lighter
/// panels, blue accents and a gold Create button.
enum Theme {
    static let base = Color(red: 0.067, green: 0.071, blue: 0.078)
    static let panel = Color(red: 0.106, green: 0.110, blue: 0.122)
    static let raised = Color(red: 0.157, green: 0.165, blue: 0.180)
    static let border = Color.white.opacity(0.07)
    static let accent = Color(red: 0.33, green: 0.62, blue: 0.96)
    static let create = Color(red: 0.96, green: 0.78, blue: 0.26)
}

/// The header of a collapsible settings group: a chevron, a title and, when collapsed,
/// a short summary of what's set inside (e.g. "Square · 1024×1024").
struct AccordionHeader: View {
    let title: String
    var summary: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let summary, !isExpanded {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Theme.raised, in: Capsule())
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A square icon button for the side rail and the image toolbar.
struct IconButtonStyle: ButtonStyle {
    var isSelected = false
    var size: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, isSelected: isSelected, size: size)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: size * 0.45))
                .foregroundStyle(isSelected ? Theme.accent : (isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.4)))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isSelected ? Theme.accent.opacity(0.18)
                              : hovering && isEnabled ? Theme.raised : .clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The gold, full-width Create button.
struct CreateButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.black.opacity(0.85) : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isEnabled ? Theme.create : Theme.raised))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Rectangle())
    }
}

/// The bar along the top of every section, the same height and look everywhere, so
/// switching sections doesn't move the top of the window around.
struct HeaderBar<Content: View>: View {
    @ViewBuilder var content: Content

    static var height: CGFloat { 44 }

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
            // Not into the title-bar strip: that stays the base colour on every section.
            .background(Theme.panel, ignoresSafeAreaEdges: [])
            .overlay(alignment: .bottom) { Divider() }
    }
}

/// A rounded search field for header bars.
struct SearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { text = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: 240, height: 28)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 7))
    }
}
