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

extension View {
    /// Applies the app typeface to this view hierarchy.
    func departureMono() -> some View { font(Theme.text) }
}
