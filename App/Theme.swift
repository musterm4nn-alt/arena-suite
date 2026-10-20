import AppKit
import CoreText
import SwiftUI

/// Departure Mono (SIL OFL 1.1, bundled with its license in Resources/Fonts). It is a pixel font:
/// sizes are multiples of 11 pt for crisp rendering.
enum Theme {
    static let fontName = "DepartureMono-Regular"
    static let body: CGFloat = 11
    static let title: CGFloat = 22

    /// Registers the bundled font for this process. Falls back to the system monospaced font if the
    /// file is missing, so the app never renders without text.
    static func registerFonts() {
        guard let url = Bundle.main.url(forResource: "DepartureMono-Regular", withExtension: "otf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    static var isAvailable: Bool { NSFont(name: fontName, size: body) != nil }

    static func font(_ size: CGFloat = body) -> Font {
        isAvailable ? .custom(fontName, fixedSize: size) : .system(size: size, design: .monospaced)
    }

    static let caption = font(body)
    static let text = font(body)
    static let heading = font(title)
}

/// Colors matched to Arena's website so the archive and the embedded site read as one app. The dark
/// values were sampled from the site's dark theme (2026-10-18): warm, neutral and opaque, no blue.
/// The light values are a matching guess; the site's light theme was not sampled.
extension Theme {
    static let background = adaptive(dark: 0x252523, light: 0xFAF9F7)
    /// Selected rows (the site darkens the selected chat).
    static let sunken = adaptive(dark: 0x1B1A19, light: 0xEFECE8)
    /// Your prompts (the site's prompt bubble), banners and bars.
    static let raised = adaptive(dark: 0x403C3A, light: 0xF0EDE8)
    static let border = adaptive(dark: 0x403D39, light: 0xE2DDD6)
    static let primaryText = adaptive(dark: 0xF3F0EC, light: 0x1B1A19)
    /// Controls (toggles, progress): a warm grey instead of the system accent.
    static let accent = adaptive(dark: 0x6B635B, light: 0x5B544C)
    /// Under the pointer: between the background and a raised surface.
    static let hover = adaptive(dark: 0x2F2D2B, light: 0xF1EEEA)

    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(
                    srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255, alpha: 1)
            })
    }
}

/// The window's layout. The window has no title bar or toolbar of its own: each pane draws a header
/// bar in the top band, where the window buttons sit (centered 16 pt from the top, ending near
/// x = 68; measured on macOS 26, 2026-10-18). The band stays draggable like a title bar.
extension Theme {
    static let barHeight: CGFloat = 32
    /// What the window buttons cover at the top-left, with a margin.
    static let windowButtonsWidth: CGFloat = 80
    static let sidebarWidth: CGFloat = 260
    static let railWidth: CGFloat = 52
}

/// How far a pane's header bar must start from its leading edge to clear the window buttons (only
/// when the sidebar is a rail, which is narrower than they are).
private struct HeaderLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var headerLeadingInset: CGFloat {
        get { self[HeaderLeadingInsetKey.self] }
        set { self[HeaderLeadingInsetKey.self] = newValue }
    }
}

/// A pane's header bar in the window's top band: leading content, then trailing controls.
struct HeaderBar<Leading: View, Trailing: View>: View {
    var divider = false
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @Environment(\.headerLeadingInset) private var inset

    var body: some View {
        HStack(spacing: 6) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, 14 + inset)
        .padding(.trailing, 8)
        .frame(height: Theme.barHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .overlay(alignment: .bottom) { if divider { Theme.border.frame(height: 1) } }
    }
}

extension View {
    /// Applies the app typeface to this view hierarchy.
    func departureMono() -> some View { font(Theme.text) }

    /// The app's palette for a window or sheet: an opaque site-matched background (no wallpaper
    /// tinting), warm text and control tint. `.secondary`/`.tertiary` derive from the warm text.
    func arenaPalette() -> some View {
        foregroundStyle(Theme.primaryText)
            .tint(Theme.accent)
            .background(Theme.background)
    }
}

/// A small bordered button like the site's pills (replaces the blue `.link` style).
struct ArenaPillStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.caption)
            .foregroundStyle(configuration.role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(Theme.primaryText))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? Theme.sunken : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == ArenaPillStyle {
    static var arenaPill: ArenaPillStyle { ArenaPillStyle() }
}

/// A borderless icon button, highlighted under the pointer (header bars, the rail, hover actions).
struct ArenaIconButtonStyle: ButtonStyle {
    var size = CGSize(width: 28, height: 24)
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, selected: selected)
    }

    private struct IconBody: View {
        let configuration: ButtonStyleConfiguration
        let size: CGSize
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .frame(width: size.width, height: size.height)
                .foregroundStyle(Theme.primaryText.opacity(isEnabled ? (hovering || selected ? 1 : 0.72) : 0.3))
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected || configuration.isPressed ? Theme.sunken : hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == ArenaIconButtonStyle {
    static var arenaIcon: ArenaIconButtonStyle { ArenaIconButtonStyle() }
    static func arenaIcon(width: CGFloat, height: CGFloat, selected: Bool = false) -> ArenaIconButtonStyle {
        ArenaIconButtonStyle(size: CGSize(width: width, height: height), selected: selected)
    }
}

/// A tab in a header bar (the site's account tabs): the selected one sunken and outlined, the others
/// dimmer, lighter under the pointer.
struct ArenaTabStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        TabBody(configuration: configuration, selected: selected)
    }

    private struct TabBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovering = false

        var body: some View {
            // As wide as the name, up to a limit; a longer name is shortened (its help has it whole).
            configuration.label
                .font(Theme.caption)
                .lineLimit(1)
                .frame(maxWidth: 200)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 9)
                .frame(height: 22)
                .foregroundStyle(Theme.primaryText.opacity(selected || hovering ? 1 : 0.7))
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected || configuration.isPressed ? Theme.sunken : hovering ? Theme.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Theme.border : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// A full-width row like the site's sidebar entries: darker when selected, lighter under the pointer.
struct ArenaRowStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(Theme.primaryText.opacity(isEnabled ? 1 : 0.4))
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(selected || configuration.isPressed ? Theme.sunken : hovering && isEnabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == ArenaRowStyle {
    static var arenaRow: ArenaRowStyle { ArenaRowStyle() }
    static func arenaRow(selected: Bool) -> ArenaRowStyle { ArenaRowStyle(selected: selected) }
}

/// A text field on the palette: a sunken rounded box with an optional leading symbol.
struct ArenaField<Field: View>: View {
    var symbol: String?
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).foregroundStyle(.secondary) }
            field.textFieldStyle(.plain).font(Theme.text)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.sunken))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.border))
    }
}

/// An account's initial in a circle (the site shows the user's avatar there).
struct AccountBadge: View {
    let text: String?
    var symbol = "person.2"
    var size: CGFloat = 24
    var active = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.raised)
            Circle().strokeBorder(active ? Theme.primaryText : Theme.border, lineWidth: active ? 1.5 : 1)
            if let text {
                Text(text).font(Theme.text)
            } else {
                Image(systemName: symbol).imageScale(.small)
            }
        }
        .frame(width: size, height: size)
    }
}
