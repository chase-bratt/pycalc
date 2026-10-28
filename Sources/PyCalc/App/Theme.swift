import AppKit
import PyCalcCore
import SwiftUI

/// "Amethyst Dawn Haze" on graphite: the five brand colours plus a few
/// complementary accents tuned for legibility on dark grey.
enum Theme {
    // Brand palette
    static let citrine = NSColor(hex: 0xDCCE40)
    static let indigo = NSColor(hex: 0x341C67)
    static let plum = NSColor(hex: 0x472F5B)
    static let lavender = NSColor(hex: 0xC4AEF4)
    static let rose = NSColor(hex: 0xCCA4B4)

    // Complements
    static let mint = NSColor(hex: 0x86E3C4)
    static let sky = NSColor(hex: 0x8EC7FF)
    static let coral = NSColor(hex: 0xFF8E8E)
    static let peach = NSColor(hex: 0xF2A779)

    // Graphite surfaces
    static let window = NSColor(hex: 0x161619)
    static let chrome = NSColor(hex: 0x1C1C20)
    static let editor = NSColor(hex: 0x19191C)
    static let gutter = NSColor(hex: 0x19191C)
    static let output = NSColor(hex: 0x161619)
    static let graph = NSColor(hex: 0x1A1A1E)
    static let hairline = NSColor(hex: 0x2C2C32)
    static let currentLine = NSColor(hex: 0x472F5B, alpha: 0.32)
    static let selection = NSColor(hex: 0x472F5B)

    // Text
    static let text = NSColor(hex: 0xE8E6EF)
    static let secondaryText = NSColor(hex: 0x9C98A8)
    static let tertiaryText = NSColor(hex: 0x6B6875)
    static let comment = NSColor(hex: 0x76727F)

    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .regular)
    static let codeFontItalic: NSFont = {
        let descriptor = codeFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 13.5) ?? codeFont
    }()
    static let codeFontMedium = NSFont.monospacedSystemFont(ofSize: 13.5, weight: .medium)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let codeLineHeight: CGFloat = 21

    static func syntaxColor(_ kind: SyntaxKind) -> NSColor {
        switch kind {
        case .keyword: return lavender
        case .constant: return mint
        case .builtin: return mint
        case .string: return rose
        case .number: return peach
        case .comment: return comment
        case .definition: return citrine
        case .call: return mint
        case .decorator: return citrine
        case .selfParameter: return rose
        case .op: return NSColor(hex: 0xB9B4C9)
        }
    }
}

typealias SyntaxKind = PythonTokenizer.Kind

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }

    /// Parses "#RRGGBB"; falls back to lavender for anything else.
    convenience init(hexString: String) {
        let digits = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            self.init(hex: 0xC4AEF4)
            return
        }
        self.init(hex: value)
    }
}

extension Color {
    init(_ nsColor: NSColor) { self.init(nsColor: nsColor) }

    static let citrine = Color(Theme.citrine)
    static let lavender = Color(Theme.lavender)
    static let rose = Color(Theme.rose)
    static let plum = Color(Theme.plum)
    static let indigo = Color(Theme.indigo)
    static let mint = Color(Theme.mint)
    static let coral = Color(Theme.coral)
    static let textPrimary = Color(Theme.text)
    static let textSecondary = Color(Theme.secondaryText)
    static let textTertiary = Color(Theme.tertiaryText)
    static let hairline = Color(Theme.hairline)
}
