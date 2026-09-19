import SwiftUI

/// Apple's macOS 27 design kit, mapped to code. System controls (Forms,
/// menus, standard button styles) pick the platform look up automatically —
/// these helpers bring the kit's type scale and content-layer materials to
/// HeyCast's custom-drawn surfaces.
///
/// Guidance applied (Materials / Text Styles pages):
/// - Liquid Glass belongs to the floating functional layer (the panel
///   background); inner surfaces use *standard* materials instead.
/// - Standalone actions use the system button style, which renders as the
///   kit's capsule push button on macOS 27.
/// - The kit type scale: Footnote 10, Subheadline 11, Callout 12, Body 13;
///   "Emphasized" is semibold (≈590).
extension Theme {
    func font(_ style: KitTextStyle) -> Font {
        if let name = fontName {
            return Font.custom(name, size: style.size).weight(style.weight)
        }
        return Font.system(style.textStyle).weight(style.weight)
    }
}

enum KitTextStyle {
    case footnote, footnoteEmphasized
    case subheadline, subheadlineEmphasized
    case callout
    case body, bodyEmphasized

    var size: CGFloat {
        switch self {
        case .footnote, .footnoteEmphasized: return 10
        case .subheadline, .subheadlineEmphasized: return 11
        case .callout: return 12
        case .body, .bodyEmphasized: return 13
        }
    }

    var weight: Font.Weight {
        switch self {
        case .footnoteEmphasized, .subheadlineEmphasized, .bodyEmphasized: return .semibold
        default: return .regular
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .footnote, .footnoteEmphasized: return .footnote
        case .subheadline, .subheadlineEmphasized: return .subheadline
        case .callout: return .callout
        case .body, .bodyEmphasized: return .body
        }
    }
}
