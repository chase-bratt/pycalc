import AppKit

/// Gutter with line numbers; the caret line is bright and an error line is coral.
final class LineNumberRuler: NSRulerView {
    private weak var codeView: CodeTextView?

    init(textView: CodeTextView) {
        self.codeView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 52
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.gutter.setFill()
        bounds.fill()
        Theme.hairline.withAlphaComponent(0.7).setFill()
        NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = codeView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let scrollView else { return }
        let text = textView.string as NSString
        let visible = scrollView.contentView.bounds
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let caretLine = lineNumber(at: textView.selectedRange().location, in: text)
        var line = lineNumber(at: characters.location, in: text)
        let offset = textView.textContainerOrigin.y - visible.minY

        func drawNumber(_ number: Int, in fragment: NSRect) {
            let color: NSColor = number == textView.errorLine ? Theme.coral
                : number == caretLine ? Theme.text : Theme.tertiaryText
            let attributes: [NSAttributedString.Key: Any] = [.font: Theme.gutterFont, .foregroundColor: color]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            let y = fragment.minY + offset + (fragment.height - size.height) / 2
            label.draw(at: NSPoint(x: ruleThickness - 18 - size.width, y: y), withAttributes: attributes)
        }

        var index = characters.location
        while index < NSMaxRange(characters) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            drawNumber(line, in: fragment)
            line += 1
            index = NSMaxRange(lineRange)
        }
        if layoutManager.extraLineFragmentTextContainer != nil {
            drawNumber(lineNumber(at: text.length, in: text), in: layoutManager.extraLineFragmentRect)
        }
    }

    private func lineNumber(at location: Int, in text: NSString) -> Int {
        CodeTextView.lineNumber(at: location, in: text)
    }
}
