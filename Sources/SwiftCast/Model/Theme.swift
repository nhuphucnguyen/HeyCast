import AppKit
import SwiftUI

/// Colors and fonts derived from the user's theme config. Dark/light presets
/// mirror RustCast's defaults; "system" follows the macOS interface style.
struct Theme {
    var textColor: Color
    var backgroundColor: Color
    var secondaryBackground: Color
    var focusedRow: Color
    var unfocusedRow: Color
    var blur: Bool
    var showIcons: Bool
    var showScrollBar: Bool
    var fontName: String?
    var isDark: Bool

    static let dark = Theme(
        textColor: Color(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1),
        backgroundColor: Color(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 0.92),
        secondaryBackground: Color(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 1),
        focusedRow: Color(srgbRed: 0.30, green: 0.30, blue: 0.34, alpha: 0.9),
        unfocusedRow: Color(srgbRed: 0.16, green: 0.16, blue: 0.19, alpha: 0.6),
        blur: true, showIcons: true, showScrollBar: false, fontName: nil, isDark: true
    )

    static let light = Theme(
        textColor: Color(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1),
        backgroundColor: Color(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 0.94),
        secondaryBackground: Color(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1),
        focusedRow: Color(srgbRed: 0.78, green: 0.78, blue: 0.82, alpha: 0.9),
        unfocusedRow: Color(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 0.6),
        blur: true, showIcons: true, showScrollBar: false, fontName: nil, isDark: false
    )

    static func resolve(config: Config, systemDark: Bool) -> Theme {
        var base: Theme
        switch config.theme.mode {
        case .dark: base = .dark
        case .light: base = .light
        case .system: base = systemDark ? .dark : .light
        }
        base.blur = config.theme.blur
        base.showIcons = config.theme.showIcons
        base.showScrollBar = config.theme.showScrollBar
        base.fontName = config.theme.fontName
        if let hex = config.theme.backgroundColor, let nsColor = NSColor(hex: hex) {
            let color = Color(nsColor: nsColor.withAlphaComponent(0.94))
            base.backgroundColor = color
            base.secondaryBackground = nsColor.lighten(0.12).swiftColor
            base.focusedRow = nsColor.lighten(0.22).swiftColor.alpha(0.9)
            base.unfocusedRow = nsColor.lighten(0.10).swiftColor.alpha(0.6)
        }
        if let hex = config.theme.textColor, let nsColor = NSColor(hex: hex) {
            base.textColor = Color(nsColor: nsColor)
        }
        return base
    }

    func uiFont(size: CGFloat) -> NSFont {
        if let name = fontName, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size)
    }
}

extension Color {
    init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        self.init(NSColor(srgbRed: r, green: g, blue: b, alpha: a))
    }

    func alpha(_ value: CGFloat) -> Color {
        Color(nsColor: NSColor(self).withAlphaComponent(value))
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    func lighten(_ amount: CGFloat) -> NSColor {
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        usingColorSpace(.sRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        return NSColor(hue: hue, saturation: sat, brightness: min(1, bri + amount), alpha: alpha)
    }

    var swiftColor: Color { Color(nsColor: self) }
}
