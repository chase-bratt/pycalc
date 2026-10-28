import AppKit
import PyCalcCore

/// The Python editor: TextKit 1 text view with auto-indent, bracket pairing,
/// the ⇧P print() expansion and a highlighted current line.
final class CodeTextView: NSTextView {
    static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
    static let closers: Set<String> = [")", "]", "}", "\"", "'"]
    static let printShortcutKey = "shiftPInsertsPrint"

    var errorLine: Int? { didSet { needsDisplay = true } }
    var onSnippetRequest: (() -> Void)?
    /// Per-line results from the last run, drawn dimmed at the right of each line.
    var annotations: [Int: String] = [:] { didSet { annotationsStale = false; needsDisplay = true } }
    /// Set once the script is edited after a run, so old values fade instead of lying.
    var annotationsStale = false { didSet { needsDisplay = true } }
    var onCopyAnnotation: ((String) -> Void)?
    var extraCompletions: () -> [String] = { [] }
    var annotationFrames: [(frame: NSRect, text: String)] = []

    // MARK: - Key handling

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if UserDefaults.standard.bool(forKey: Self.printShortcutKey), !hasMarkedText(), modifiers == [.shift], event.charactersIgnoringModifiers?.lowercased() == "p",
           EditorRules.shouldExpandPrint(in: string, at: selectedRange().location) || selectedRange().length > 0 {
            onSnippetRequest?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let cursor = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
        let beforeCursor = text.substring(with: NSRange(location: lineRange.location, length: cursor - lineRange.location))
        var indent = EditorRules.indentation(after: beforeCursor)
        // Between a bracket pair, open an indented line and put the closer below.
        if cursor > 0, cursor < text.length,
           let close = Self.pairs[text.substring(with: NSRange(location: cursor - 1, length: 1))],
           close != "\"", close != "'",
           text.substring(with: NSRange(location: cursor, length: 1)) == close {
            let outer = String(beforeCursor.prefix { $0 == " " })
            indent = outer + EditorRules.indentUnit
            replace(selectedRange(), with: "\n" + indent + "\n" + outer, caret: cursor + 1 + indent.utf16.count)
            return
        }
        replace(selectedRange(), with: "\n" + indent, caret: nil)
    }

    override func insertTab(_ sender: Any?) {
        if selectedRange().length > 0, (string as NSString).substring(with: selectedRange()).contains("\n") {
            shiftSelectedLines(by: 1)
        } else {
            let cursor = selectedRange().location
            let lineStart = (string as NSString).lineRange(for: NSRange(location: cursor, length: 0)).location
            let column = cursor - lineStart
            let spaces = 4 - column % 4
            insertText(String(repeating: " ", count: spaces), replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        shiftSelectedLines(by: -1)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let typed = insertString as? String, typed.count == 1, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let text = string as NSString
        let selection = selectedRange()
        let next = selection.location < text.length ? text.substring(with: NSRange(location: selection.location, length: 1)) : ""
        // Step over a closer that is already there.
        if selection.length == 0, Self.closers.contains(typed), next == typed {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        if let close = Self.pairs[typed], shouldAutoPair(typed, next: next, at: selection) {
            if selection.length > 0 {
                let inner = text.substring(with: selection)
                replace(selection, with: typed + inner + close, caret: nil, select: NSRange(location: selection.location + 1, length: inner.utf16.count))
            } else {
                replace(selection, with: typed + close, caret: selection.location + 1)
            }
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func deleteBackward(_ sender: Any?) {
        let text = string as NSString
        let selection = selectedRange()
        guard selection.length == 0, selection.location > 0 else { return super.deleteBackward(sender) }
        let cursor = selection.location
        // Delete an empty pair together.
        if cursor < text.length {
            let previous = text.substring(with: NSRange(location: cursor - 1, length: 1))
            let next = text.substring(with: NSRange(location: cursor, length: 1))
            if Self.pairs[previous] == next {
                replace(NSRange(location: cursor - 1, length: 2), with: "", caret: nil)
                return
            }
        }
        // Inside leading whitespace, delete back to the previous indent stop.
        let lineStart = text.lineRange(for: NSRange(location: cursor, length: 0)).location
        let leading = text.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
        if !leading.isEmpty, leading.allSatisfy({ $0 == " " }) {
            let remove = leading.count % 4 == 0 ? 4 : leading.count % 4
            replace(NSRange(location: cursor - remove, length: remove), with: "", caret: nil)
            return
        }
        super.deleteBackward(sender)
    }

    private func shouldAutoPair(_ typed: String, next: String, at selection: NSRange) -> Bool {
        if selection.length > 0 { return true }
        let nextIsOpen = next.isEmpty || next.first?.isWhitespace == true || Self.closers.contains(next) || next == "," || next == ":"
        guard typed == "\"" || typed == "'" else { return nextIsOpen }
        let text = string as NSString
        let previous = selection.location > 0 ? text.substring(with: NSRange(location: selection.location - 1, length: 1)) : ""
        let previousIsWord = previous.first.map { $0.isLetter || $0.isNumber || $0 == "_" } ?? false
        return nextIsOpen && !previousIsWord
    }

    // MARK: - Editing helpers

    /// Undoable replacement that keeps highlighting and delegates in the loop.
    func replace(_ range: NSRange, with replacement: String, caret: Int?, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        if let select { setSelectedRange(select) }
        else { setSelectedRange(NSRange(location: caret ?? range.location + replacement.utf16.count, length: 0)) }
        scrollRangeToVisible(selectedRange())
    }

    func shiftSelectedLines(by levels: Int) {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        let block = text.substring(with: range)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let shifted = lines.map { line -> String in
            if levels > 0 { return line.isEmpty ? line : EditorRules.indentUnit + line }
            let strip = min(4, line.prefix { $0 == " " }.count)
            return String(line.dropFirst(strip))
        }
        let result = shifted.joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        replace(range, with: result, caret: nil, select: NSRange(location: range.location, length: result.utf16.count))
    }

    func toggleCommentOnSelectedLines() {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        let block = text.substring(with: range)
        let hasTrailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if hasTrailingNewline { lines.removeLast() }
        let result = EditorRules.toggleComment(lines).joined(separator: "\n") + (hasTrailingNewline ? "\n" : "")
        let wasCaret = selectedRange().length == 0
        replace(range, with: result, caret: nil,
                select: wasCaret ? NSRange(location: min(selectedRange().location, range.location + result.utf16.count), length: 0)
                                 : NSRange(location: range.location, length: result.utf16.count))
    }

    /// 1-based line containing a UTF-16 offset (counts LF code units, like the gutter).
    static func lineNumber(at location: Int, in text: NSString) -> Int {
        var count = 1
        var cursor = 0
        let limit = min(location, text.length)
        while cursor < limit {
            let found = text.range(of: "\n", range: NSRange(location: cursor, length: limit - cursor))
            guard found.location != NSNotFound else { break }
            count += 1
            cursor = found.location + 1
        }
        return count
    }

    /// Pasted Windows/classic-Mac line endings become LF so line numbers stay in sync with Python.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let pasted = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        let normalized = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        insertText(normalized, replacementRange: selectedRange())
        return true
    }

    // MARK: - Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let errorLine, let lineRect = rectForLine(errorLine) {
            Theme.coral.withAlphaComponent(0.12).setFill()
            lineRect.fill()
            Theme.coral.setFill()
            NSRect(x: lineRect.minX, y: lineRect.minY, width: 2, height: lineRect.height).fill()
        } else if selectedRange().length == 0, let lineRect = rectForCaretLine() {
            Theme.currentLine.setFill()
            lineRect.fill()
            Theme.lavender.setFill()
            NSRect(x: lineRect.minX, y: lineRect.minY, width: 2, height: lineRect.height).fill()
        }
        drawAnnotations(in: rect)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        needsDisplay = true
    }

    private func rectForCaretLine() -> NSRect? {
        let text = string as NSString
        let cursor = min(selectedRange().location, text.length)
        return rectForLine(Self.lineNumber(at: cursor, in: text))
    }

    func rectForLine(_ line: Int) -> NSRect? {
        guard let layoutManager else { return nil }
        let text = string as NSString
        var location = 0
        var current = 1
        while current < line {
            let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { return nil }
            location = next.location + 1
            current += 1
        }
        var fragment: NSRect
        if location >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            fragment = layoutManager.extraLineFragmentRect
        } else if location < text.length || text.length == 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(text.length - 1, 0)))
            fragment = text.length == 0 ? layoutManager.extraLineFragmentRect
                : layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        } else {
            return nil
        }
        fragment.origin.x = 0
        fragment.origin.y += textContainerOrigin.y
        fragment.size.width = bounds.width
        return fragment
    }
}
