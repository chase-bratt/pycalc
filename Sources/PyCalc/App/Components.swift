import AppKit
import SwiftUI

/// Small rounded key glyph, e.g. ⌘↵.
struct Keycap: View {
    let keys: String
    var tint: Color = .textSecondary
    var fill: Color = Color.white.opacity(0.06)

    var body: some View {
        Text(keys)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 17)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
    }
}

/// "OUTPUT  Ran in 6 ms" style section header.
struct PaneHeader<Trailing: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(Color.textSecondary)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
                .lineLimit(1)
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color(Theme.chrome))
        .overlay(alignment: .bottom) { Color.hairline.frame(height: 1) }
    }
}

/// Plain borderless icon button with a soft hover fill.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovering ? Color.textPrimary : Color.textSecondary)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Two panes separated by a hairline the user can drag.
struct SplitPane<First: View, Second: View>: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var fraction: Double
    var range: ClosedRange<Double> = 0.2...0.8
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = axis == .horizontal ? proxy.size.width : proxy.size.height
            let split = total * fraction
            let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first.frame(width: axis == .horizontal ? split : nil, height: axis == .vertical ? split : nil)
                Color.hairline
                    .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
                    .overlay(handle(total: total))
                second.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handle(total: CGFloat) -> some View {
        Color.clear
            .frame(width: axis == .horizontal ? 9 : nil, height: axis == .vertical ? 9 : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                let cursor: NSCursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStart ?? fraction
                    dragStart = start
                    let delta = axis == .horizontal ? value.translation.width : value.translation.height
                    fraction = min(max(start + Double(delta / max(total, 1)), range.lowerBound), range.upperBound)
                }
                .onEnded { _ in dragStart = nil })
    }
}

/// Configures the hosting window: transparent title bar, and traffic lights
/// re-centred inside the taller custom title bar.
struct WindowConfigurator: NSViewRepresentable {
    let titlebarHeight: CGFloat
    var onWindow: (NSWindow) -> Void = { _ in }

    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let height = titlebarHeight
        let onWindow = onWindow
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            onWindow(window)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = Theme.window
            window.isMovableByWindowBackground = false
            window.setFrameAutosaveName("PyCalcMainWindow")
            Self.positionTrafficLights(in: window, barHeight: height)
            let names: [Notification.Name] = [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                                              NSWindow.didBecomeKeyNotification]
            context.coordinator.observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { Self.positionTrafficLights(in: window, barHeight: height) }
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor
    static func positionTrafficLights(in window: NSWindow, barHeight: CGFloat) {
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let container = close.superview?.superview else { return }
        var frame = container.frame
        frame.size.height = barHeight
        frame.origin.y = window.frame.height - barHeight
        container.frame = frame
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = window.standardWindowButton(type) else { continue }
            button.setFrameOrigin(NSPoint(x: 14 + CGFloat(index) * 20,
                                          y: (barHeight - button.frame.height) / 2))
        }
    }
}

/// Lets the custom title bar drag the window and zoom on double-click.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
