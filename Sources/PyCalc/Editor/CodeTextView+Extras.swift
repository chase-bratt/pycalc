import AppKit
import PyCalcCore

/// Inline line results and name completion.
extension CodeTextView {
    private static let annotationFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    func drawAnnotations(in dirtyRect: NSRect) {
        annotationFrames = []
        guard !annotations.isEmpty, let layoutManager else { return }
        let text = string as NSString
        let visible = visibleRect
        let color = Theme.lavender.withAlphaComponent(annotationsStale ? 0.28 : 0.62)
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.annotationFont, .foregroundColor: color]
        for (line, value) in annotations.sorted(by: { $0.key < $1.key }) {
            guard let lineRect = rectForLine(line), lineRect.intersects(dirtyRect) else { continue }
            let label = "= \(value)" as NSString
            let size = label.size(withAttributes: attributes)
            // Right-align in the visible area, but never on top of the code itself.
            let lineEnd = lineEndX(line: line, in: text, layoutManager: layoutManager)
            let x = max(lineEnd + 28, visible.maxX - size.width - 18)
            let frame = NSRect(x: x, y: lineRect.midY - size.height / 2 + 1, width: size.width, height: size.height)
            label.draw(at: frame.origin, withAttributes: attributes)
            annotationFrames.append((frame.insetBy(dx: -4, dy: -2), value))
        }
    }

    private func lineEndX(line: Int, in text: NSString, layoutManager: NSLayoutManager) -> CGFloat {
        var location = 0
        for _ in 1..<line {
            let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { return textContainerOrigin.x }
            location = next.location + 1
        }
        let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let content = NSRange(location: lineRange.location, length: max(0, lineRange.length - (text.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)))
        guard content.length > 0, let container = textContainer else { return textContainerOrigin.x }
        let glyphs = layoutManager.glyphRange(forCharacterRange: content, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container).maxX + textContainerOrigin.x
    }

    /// Clicking an inline result copies it.
    func annotation(at point: NSPoint) -> String? {
        annotationFrames.first { $0.frame.contains(point) }?.text
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let value = annotation(at: point) {
            onCopyAnnotation?(value)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        annotationFrames.forEach { addCursorRect($0.frame, cursor: .pointingHand) }
    }

    // MARK: - Completion (Esc, F5 or ⌥Esc)

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let source = string
        let inStringOrComment = PythonTokenizer.tokenize(source).contains { token in
            (token.kind == .string || token.kind == .comment) &&
                token.location < charRange.location && charRange.location < token.location + token.length
        }
        guard !inStringOrComment else { return nil }
        let prefix = (source as NSString).substring(with: charRange)
        let names = EditorRules.completions(for: prefix, in: source, extra: extraCompletions())
        index.pointee = names.isEmpty ? -1 : 0
        return names
    }
}
