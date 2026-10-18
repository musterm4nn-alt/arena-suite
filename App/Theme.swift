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

extension View {
    /// Applies the app typeface to this view hierarchy.
    func departureMono() -> some View { font(Theme.text) }

    /// The app's palette for a window or sheet: an opaque site-matched background (no wallpaper
    /// tinting), warm text and control tint. `.secondary`/`.tertiary` derive from the warm text.
    func arenaPalette() -> some View {
        foregroundStyle(Theme.primaryText)
            .tint(Theme.accent)
            .background(Theme.background)
            .toolbarBackground(Theme.background, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
    }

    /// A list or scroll view drawn on the palette instead of the system background or material.
    func arenaBackground(_ color: Color = Theme.background) -> some View {
        scrollContentBackground(.hidden).background(color)
    }

    /// A sheet on the palette. Done stays a confirmation toolbar item (with a Done button inside the
    /// sheet instead, the app refused to quit while the sheet was open), drawn as a pill; the system
    /// still draws that toolbar's footer strip in its own color.
    func arenaSheet(doneDisabled: Bool = false, done: @escaping () -> Void) -> some View {
        buttonStyle(.arenaPill)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done).buttonStyle(.arenaPill).disabled(doneDisabled)
                }
            }
            .arenaPalette()
            .departureMono()
    }

    /// The site's selected-row look: a darker, rounded background.
    func arenaSelection(_ selected: Bool) -> some View {
        padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.sunken : .clear))
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
