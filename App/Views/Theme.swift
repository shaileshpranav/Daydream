import SwiftUI

/// A panel-based look inspired by InvokeAI: a near-black base (light grey in light mode),
/// slightly lighter panels, blue accents and a gold Create button.
enum Theme {
    static let base = adaptive(light: (0.925, 0.930, 0.940), dark: (0.067, 0.071, 0.078))
    static let panel = adaptive(light: (0.965, 0.968, 0.975), dark: (0.106, 0.110, 0.122))
    static let raised = adaptive(light: (0.875, 0.882, 0.898), dark: (0.157, 0.165, 0.180))
    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor.white.withAlphaComponent(0.07) : NSColor.black.withAlphaComponent(0.09)
    })
    static let accent = adaptive(light: (0.10, 0.45, 0.88), dark: (0.33, 0.62, 0.96))
    static let create = adaptive(light: (0.95, 0.72, 0.15), dark: (0.96, 0.78, 0.26))

    /// A colour that follows the window's light or dark appearance.
    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = isDark(appearance) ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

/// A circular progress ring; `fraction` nil spins (for "getting ready" with no steps yet).
struct ProgressRing: View {
    let fraction: Double?
    var lineWidth: CGFloat = 4
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(Theme.border, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction.map { max(0.02, min($0, 1)) } ?? 0.28)
                .stroke(AngularGradient(colors: [Theme.accent.opacity(0.6), Theme.accent], center: .center),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90 + (fraction == nil && spinning ? 360 : 0)))
                .animation(fraction == nil ? .linear(duration: 1).repeatForever(autoreverses: false) : .easeOut(duration: 0.3),
                           value: fraction == nil ? (spinning ? 1 : 0) : fraction ?? 0)
        }
        .padding(lineWidth / 2)
        .onAppear { spinning = true }
    }
}

/// A tab with its icon above a short label, sharing the row's width with its siblings
/// (Edit's tool picker).
struct ToolTabStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, isSelected: isSelected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyle.Configuration
        let isSelected: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(TabLabelStyle())
                .foregroundStyle(isSelected ? Theme.accent : Color.primary.opacity(0.8))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Theme.accent.opacity(0.16) : hovering ? Theme.raised : .clear))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }

    private struct TabLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            VStack(spacing: 4) {
                // A fixed box so icons of different heights keep the labels on one line.
                configuration.icon
                    .font(.system(size: 15))
                    .frame(height: 18)
                configuration.title
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 2)
        }
    }
}

/// The Daydream mark: the gold sparkle from the app icon, for the top of the side rail.
struct AppMark: View {
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.92, blue: 0.62), Theme.create],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            .shadow(color: Theme.create.opacity(0.5), radius: 6)
            .frame(width: size, height: size)
            .accessibilityLabel("Daydream")
    }
}

/// Light, dark, or following macOS (Settings → General, and View → Appearance).
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Applied to the whole app (windows, menus, sheets); nil follows macOS.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
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
