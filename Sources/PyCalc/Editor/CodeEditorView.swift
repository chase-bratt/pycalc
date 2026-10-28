import AppKit
import PyCalcCore
import SwiftUI

/// Bridges the AppKit editor to the model: commands go in, text and cursor come out.
@MainActor
final class EditorController {
    weak var textView: CodeTextView?
    var onChange: ((String) -> Void)?
    var onCursor: ((Int, Int) -> Void)?
    var onCopy: ((String) -> Void)?
    /// Extra names for completion, e.g. variables from the last run.
    var completionNames: () -> [String] = { [] }
    private var pendingText = ""

    var text: String {
        get { textView?.string ?? pendingText }
        set {
            pendingText = newValue
            textView?.string = newValue
        }
    }

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Wraps the selection, or places the caret between `prefix` and `suffix`.
    func insertSnippet(prefix: String, suffix: String) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let inner = (textView.string as NSString).substring(with: selection)
        let caret = selection.location + prefix.utf16.count + inner.utf16.count
        textView.replace(selection, with: prefix + inner + suffix, caret: caret)
        focus()
    }

    /// Undoable whole-document replacement (⌘Z brings the previous script back).
    func replaceAll(with rawText: String) {
        let newText = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard let textView else { text = newText; return }
        textView.replace(NSRange(location: 0, length: (textView.string as NSString).length), with: newText, caret: 0)
        scrollToTopLeft()
        clearErrorLine()
        focus()
    }

    /// The gutter is a content inset on the clip view, so the top-left is at (-left, -top), not .zero.
    /// Done on the next pass, after layout has resized the text view.
    func scrollToTopLeft() {
        DispatchQueue.main.async { [weak textView] in
            guard let scrollView = textView?.enclosingScrollView else { return }
            let insets = scrollView.contentView.contentInsets
            scrollView.contentView.scroll(to: NSPoint(x: -insets.left, y: -insets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func toggleComment() {
        textView?.toggleCommentOnSelectedLines()
    }

    func markErrorLine(_ line: Int, scroll: Bool = true) {
        textView?.errorLine = line
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        if scroll, let rect = textView?.rectForLine(line) { textView?.scrollToVisible(rect.insetBy(dx: 0, dy: -40)) }
    }

    func showAnnotations(_ annotations: [Int: String]) {
        guard let textView else { return }
        textView.annotations = annotations
        textView.window?.invalidateCursorRects(for: textView)
    }

    func clearErrorLine() {
        guard textView?.errorLine != nil else { return }
        textView?.errorLine = nil
        textView?.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

struct CodeEditorView: NSViewRepresentable {
    let controller: EditorController
    let onSnippet: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CodeTextView(usingTextLayoutManager: false)
        configure(textView)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.onSnippetRequest = onSnippet
        textView.onCopyAnnotation = { [weak controller] value in controller?.onCopy?(value) }
        textView.extraCompletions = { [weak controller] in controller?.completionNames() ?? [] }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editor
        scrollView.contentView.postsBoundsChangedNotifications = true

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.observeScrolling(of: scrollView, ruler: ruler)
        let initial = controller.text
        controller.textView = textView
        textView.string = initial
        context.coordinator.highlight(textView.textStorage)
        DispatchQueue.main.async { controller.focus() }
        controller.scrollToTopLeft()
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    private func configure(_ textView: CodeTextView) {
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editor
        textView.insertionPointColor = Theme.citrine
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection.withAlphaComponent(0.9)]
        textView.font = Theme.codeFont
        textView.textColor = Theme.text
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.defaultParagraphStyle = Coordinator.paragraphStyle
        textView.typingAttributes = Coordinator.baseAttributes
        // No wrapping: code lines scroll horizontally like a real editor.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 8
        textView.setAccessibilityLabel("Python script editor")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = Theme.codeLineHeight
            style.maximumLineHeight = Theme.codeLineHeight
            style.tabStops = []
            style.defaultTabInterval = 4 * ("0" as NSString).size(withAttributes: [.font: Theme.codeFont]).width
            return style
        }()

        static let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: Theme.codeFont,
            .foregroundColor: Theme.text,
            .paragraphStyle: paragraphStyle,
            .baselineOffset: 3,
            .ligature: 0,
        ]

        let controller: EditorController
        private var scrollObserver: NSObjectProtocol?

        init(controller: EditorController) {
            self.controller = controller
        }

        func observeScrolling(of scrollView: NSScrollView, ruler: NSRulerView) {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
            ) { [weak ruler] _ in
                MainActor.assumeIsolated { ruler?.needsDisplay = true }
            }
        }

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated { highlight(textStorage) }
        }

        func highlight(_ storage: NSTextStorage?) {
            guard let storage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes(Self.baseAttributes, range: full)
            for token in PythonTokenizer.tokenize(storage.string) {
                let range = NSRange(location: token.location, length: token.length)
                guard NSMaxRange(range) <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: Theme.syntaxColor(token.kind), range: range)
                switch token.kind {
                case .comment: storage.addAttribute(.font, value: Theme.codeFontItalic, range: range)
                case .keyword, .definition: storage.addAttribute(.font, value: Theme.codeFontMedium, range: range)
                default: break
                }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? CodeTextView else { return }
            controller.clearErrorLine()
            if !textView.annotations.isEmpty { textView.annotationsStale = true }
            controller.onChange?(textView.string)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? CodeTextView else { return }
            let text = textView.string as NSString
            let cursor = min(textView.selectedRange().location, text.length)
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let line = CodeTextView.lineNumber(at: cursor, in: text)
            controller.onCursor?(line, cursor - lineRange.location + 1)
            textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
    }
}
