import Foundation

/// Pure text rules behind the editor's conveniences, kept here so they are testable.
public enum EditorRules {
    public static let indentUnit = "    "

    /// ⇧P inserts `print()` only where a capital P could not start or continue
    /// a name: not inside a string or comment, and not right after an identifier
    /// character or a dot. Everywhere else it types a normal "P".
    public static func shouldExpandPrint(in source: String, at cursor: Int) -> Bool {
        let units = Array(source.utf16)
        guard cursor >= 0, cursor <= units.count else { return false }
        if cursor > 0 {
            let previous = units[cursor - 1]
            let isWordChar = (previous >= 0x30 && previous <= 0x39) || (previous >= 0x41 && previous <= 0x5A) ||
                (previous >= 0x61 && previous <= 0x7A) || previous == 0x5F || previous == 0x2E || previous >= 0x80
            if isWordChar { return false }
        }
        if cursor < units.count {
            let next = units[cursor]
            let isWordChar = (next >= 0x30 && next <= 0x39) || (next >= 0x41 && next <= 0x5A) ||
                (next >= 0x61 && next <= 0x7A) || next == 0x5F || next >= 0x80
            if isWordChar { return false }
        }
        return !PythonTokenizer.tokenize(source).contains { token in
            (token.kind == .string || token.kind == .comment) &&
                token.location < cursor && cursor <= token.location + token.length &&
                !(token.kind == .string && cursor == token.location + token.length && isClosed(token, units))
        }
    }

    /// Names offered by completion before anything in the script itself.
    public static let knownNames: [String] = [
        // math
        "acos", "acosh", "asin", "asinh", "atan", "atan2", "atanh", "ceil", "comb", "copysign", "cos", "cosh",
        "degrees", "dist", "e", "erf", "exp", "expm1", "fabs", "factorial", "floor", "fmod", "fsum", "gamma",
        "gcd", "hypot", "inf", "isclose", "isqrt", "lcm", "log", "log10", "log1p", "log2", "nan", "perm", "pi",
        "prod", "radians", "remainder", "sin", "sinh", "sqrt", "tan", "tanh", "tau", "trunc",
        // calculator + plotting
        "ans", "plot", "scatter", "line", "point", "parametric", "polar", "vline", "window", "cmath", "math",
        // builtins and keywords
        "abs", "all", "any", "bin", "bool", "dict", "divmod", "enumerate", "filter", "float", "format", "hex",
        "int", "isinstance", "lambda", "len", "list", "map", "max", "min", "print", "range", "return", "round",
        "set", "sorted", "str", "sum", "tuple", "zip", "import", "while", "for", "def", "class", "True", "False", "None",
    ]

    /// Completion candidates for `prefix`: known names plus identifiers already in the script.
    public static func completions(for prefix: String, in source: String, extra: [String] = []) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var seen = Set<String>()
        var scriptNames: [String] = []
        var current = ""
        for scalar in source.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                current.unicodeScalars.append(scalar)
            } else {
                if let first = current.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) { scriptNames.append(current) }
                current = ""
            }
        }
        if let first = current.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) { scriptNames.append(current) }
        let lowered = prefix.lowercased()
        return (extra + scriptNames + knownNames).filter { name in
            name != prefix && name.lowercased().hasPrefix(lowered) && seen.insert(name).inserted
        }.sorted { a, b in a.count == b.count ? a < b : a.count < b.count }
    }

    /// Indentation for a new line typed after `line`: keep its indent, add one level after a colon.
    public static func indentation(after line: String) -> String {
        let leading = String(line.prefix { $0 == " " || $0 == "\t" })
        var code = line
        if let hash = line.firstIndex(of: "#") { code = String(line[..<hash]) }
        return code.trimmingCharacters(in: .whitespaces).hasSuffix(":") ? leading + indentUnit : leading
    }

    /// Toggles a `# ` prefix on every line; uncomments only if all non-blank lines are commented.
    public static func toggleComment(_ lines: [String]) -> [String] {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let indent = content.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { line in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                guard let hash = line.firstIndex(of: "#") else { return line }
                var rest = line[line.index(after: hash)...]
                if rest.first == " " { rest = rest.dropFirst() }
                return String(line[..<hash]) + rest
            }
            let index = line.index(line.startIndex, offsetBy: indent)
            return String(line[..<index]) + "# " + line[index...]
        }
    }

    private static func isClosed(_ token: PythonTokenizer.Token, _ units: [UInt16]) -> Bool {
        guard token.length >= 2 else { return false }
        return units[token.location + token.length - 1] == 0x22 || units[token.location + token.length - 1] == 0x27
    }
}
