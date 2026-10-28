import Foundation

/// A lightweight Python lexer for syntax colouring. Ranges are UTF-16
/// offsets so they map directly onto `NSRange` in a text view.
public enum PythonTokenizer {
    public enum Kind: Equatable, Sendable {
        case keyword, constant, builtin, string, number, comment
        case definition, call, decorator, selfParameter, op
    }

    public struct Token: Equatable, Sendable {
        public let kind: Kind
        public let location: Int
        public let length: Int
    }

    static let keywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
        "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in",
        "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while",
        "with", "yield", "match", "case",
    ]
    static let constants: Set<String> = ["True", "False", "None", "pi", "e", "tau", "inf", "nan"]
    static let builtins: Set<String> = [
        "abs", "all", "any", "bin", "bool", "chr", "dict", "divmod", "enumerate", "filter", "float",
        "format", "hex", "int", "isinstance", "len", "list", "map", "max", "min", "oct", "ord", "pow",
        "print", "range", "repr", "reversed", "round", "set", "sorted", "str", "sum", "tuple", "type", "zip",
        "plot", "scatter", "line", "point", "parametric", "polar", "vline", "window",
    ]
    private static let stringPrefixes: Set<String> = ["r", "u", "f", "b", "rb", "br", "fr", "rf"]

    public static func tokenize(_ source: String) -> [Token] {
        var scanner = Scanner(units: Array(source.utf16))
        return scanner.run()
    }

    private struct Scanner {
        let units: [UInt16]
        var index = 0
        var tokens: [Token] = []
        var previousWord: String?

        init(units: [UInt16]) { self.units = units }

        mutating func run() -> [Token] {
            while index < units.count {
                let unit = units[index]
                if unit == 0x23 { comment() }                              // #
                else if unit == 0x22 || unit == 0x27 { string(start: index) } // " '
                else if isDigit(unit) || (unit == 0x2E && isDigit(peek(1))) { number() }
                else if isIdentifierStart(unit) { word() }
                else if unit == 0x40, lineStart() == index { decorator() }       // @ at line start
                else if isOperator(unit) { emit(.op, index, 1); index += 1; previousWord = nil }
                else { if !isSpace(unit) { previousWord = nil }; index += 1 }
            }
            return tokens
        }

        mutating func comment() {
            let start = index
            while index < units.count, units[index] != 0x0A { index += 1 }
            emit(.comment, start, index - start)
        }

        mutating func string(start: Int) {
            let quote = units[index]
            let triple = peek(1) == quote && peek(2) == quote
            index += triple ? 3 : 1
            while index < units.count {
                let unit = units[index]
                if unit == 0x5C { index += 2; continue }                   // backslash escape
                if !triple, unit == 0x0A { break }
                if unit == quote {
                    if !triple { index += 1; break }
                    if peek(1) == quote, peek(2) == quote { index += 3; break }
                }
                index += 1
            }
            index = min(index, units.count)
            emit(.string, start, index - start)
            previousWord = nil
        }

        mutating func number() {
            let start = index
            if units[index] == 0x30, [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(peek(1)) {     // 0x 0o 0b
                index += 2
                while index < units.count, isHexDigit(units[index]) || units[index] == 0x5F { index += 1 }
            } else {
                while index < units.count {
                    let unit = units[index]
                    if isDigit(unit) || unit == 0x5F || unit == 0x2E { index += 1 }
                    else if unit == 0x65 || unit == 0x45 {                  // exponent
                        index += 1
                        if index < units.count, units[index] == 0x2B || units[index] == 0x2D { index += 1 }
                    } else { break }
                }
                if index < units.count, units[index] == 0x6A || units[index] == 0x4A { index += 1 } // complex j
            }
            emit(.number, start, index - start)
            previousWord = nil
        }

        mutating func word() {
            let start = index
            while index < units.count, isIdentifierPart(units[index]) { index += 1 }
            let text = String(utf16CodeUnits: Array(units[start..<index]), count: index - start)
            if index < units.count, (units[index] == 0x22 || units[index] == 0x27), stringPrefixes.contains(text.lowercased()) {
                string(start: start)
                return
            }
            let kind: Kind?
            if previousWord == "def" || previousWord == "class" { kind = .definition }
            else if keywords.contains(text) { kind = .keyword }
            else if constants.contains(text) { kind = .constant }
            else if text == "self" || text == "cls" { kind = .selfParameter }
            else if builtins.contains(text) { kind = .builtin }
            else if nextNonSpace() == 0x28 { kind = .call }
            else { kind = nil }
            if let kind { emit(kind, start, index - start) }
            previousWord = text
        }

        mutating func decorator() {
            let start = index
            index += 1
            while index < units.count, isIdentifierPart(units[index]) || units[index] == 0x2E { index += 1 }
            emit(.decorator, start, index - start)
        }

        mutating func emit(_ kind: Kind, _ location: Int, _ length: Int) {
            if length > 0 { tokens.append(Token(kind: kind, location: location, length: length)) }
        }

        func peek(_ offset: Int) -> UInt16 {
            index + offset < units.count ? units[index + offset] : 0
        }

        func nextNonSpace() -> UInt16 {
            var cursor = index
            while cursor < units.count, units[cursor] == 0x20 { cursor += 1 }
            return cursor < units.count ? units[cursor] : 0
        }

        func lineStart() -> Int {
            var cursor = index - 1
            while cursor >= 0, units[cursor] == 0x20 || units[cursor] == 0x09 { cursor -= 1 }
            return cursor < 0 || units[cursor] == 0x0A ? index : -1
        }

        func isDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
        func isHexDigit(_ u: UInt16) -> Bool { isDigit(u) || (u >= 0x41 && u <= 0x46) || (u >= 0x61 && u <= 0x66) }
        func isSpace(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }
        func isIdentifierStart(_ u: UInt16) -> Bool {
            (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || u == 0x5F || u >= 0x80
        }
        func isIdentifierPart(_ u: UInt16) -> Bool { isIdentifierStart(u) || isDigit(u) }
        func isOperator(_ u: UInt16) -> Bool {
            [0x2B, 0x2D, 0x2A, 0x2F, 0x25, 0x3D, 0x3C, 0x3E, 0x21, 0x26, 0x7C, 0x5E, 0x7E, 0x40].contains(u)
        }
    }
}
