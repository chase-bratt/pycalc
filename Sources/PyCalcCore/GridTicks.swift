import Foundation

/// Grid spacing that follows the 1–2–5 progression, like a graphing calculator.
public struct GridSpacing: Equatable, Sendable {
    public let major: Double
    public let minor: Double

    /// Picks a major step whose on-screen length is at least `targetPoints`.
    public static func forScale(_ scale: Double, targetPoints: Double = 96) -> GridSpacing {
        let raw = targetPoints / scale
        let exponent = floor(log10(raw))
        let base = pow(10, exponent)
        let mantissa = raw / base
        let (step, divisions): (Double, Double) =
            mantissa <= 1 ? (1, 5) :
            mantissa <= 2 ? (2, 4) :
            mantissa <= 5 ? (5, 5) : (10, 5)
        let major = step * base
        return GridSpacing(major: major, minor: major / divisions)
    }

    /// Multiples of `step` within `range`, as exact integer multiples to avoid drift.
    public static func ticks(in range: ClosedRange<Double>, step: Double, limit: Int = 4000) -> [Double] {
        guard step > 0, step.isFinite else { return [] }
        let first = (range.lowerBound / step).rounded(.up)
        let last = (range.upperBound / step).rounded(.down)
        guard last >= first, last - first < Double(limit) else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * step }
    }
}

/// Formats axis and coordinate numbers compactly.
public enum NumberFormat {
    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹", "-": "⁻",
    ]

    /// Tick label for a value on a grid with the given step.
    public static func tick(_ value: Double, step: Double) -> String {
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e6 || magnitude < 1e-4 {
            return scientific(value, significant: max(1, significantDigits(step: step, value: value)))
        }
        let decimals = max(0, Int(-floor(log10(step))))
        return trim(String(format: "%.\(decimals)f", value))
    }

    /// Coordinate readout with a fixed number of significant digits.
    public static func coordinate(_ value: Double, significant: Int = 5) -> String {
        guard value.isFinite else { return "undefined" }
        if value == 0 { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1e7 || magnitude < 1e-4 {
            return scientific(value, significant: significant)
        }
        let decimals = max(0, significant - 1 - Int(floor(log10(magnitude))))
        let text = trim(String(format: "%.\(decimals)f", value))
        return text == "-0" ? "0" : text
    }

    public static func scientific(_ value: Double, significant: Int) -> String {
        let exponent = Int(floor(log10(abs(value))))
        let mantissa = value / pow(10, Double(exponent))
        let mantissaText = trim(String(format: "%.\(max(0, significant - 1))f", mantissa))
        let power = String(String(exponent).compactMap { superscripts[$0] })
        return mantissaText == "1" ? "10\(power)" :
            mantissaText == "-1" ? "-10\(power)" : "\(mantissaText)×10\(power)"
    }

    private static func significantDigits(step: Double, value: Double) -> Int {
        Int(floor(log10(abs(value)))) - Int(floor(log10(step))) + 1
    }

    private static func trim(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.hasSuffix("0") { result.removeLast() }
        if result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
