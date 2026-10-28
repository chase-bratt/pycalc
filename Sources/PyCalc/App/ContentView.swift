import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("split.horizontal") private var horizontalSplit = 0.5
    @AppStorage("split.vertical") private var verticalSplit = 0.44
    private let titlebarHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(height: titlebarHeight)
            HStack(spacing: 0) {
                if model.showHistory {
                    HistorySidebar()
                        .frame(width: 270)
                        .overlay(alignment: .trailing) { Color.hairline.frame(width: 1) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                SplitPane(axis: .horizontal, fraction: $horizontalSplit, range: 0.28...0.72) {
                    EditorPane()
                } second: {
                    SplitPane(axis: .vertical, fraction: $verticalSplit, range: 0.15...0.85) {
                        OutputPane()
                    } second: {
                        GraphPane(controller: model.graph)
                    }
                }
            }
            StatusBar(status: model.editorStatus)
        }
        .background(Color(Theme.window))
        .ignoresSafeArea()
        .background(WindowConfigurator(titlebarHeight: titlebarHeight) { model.window = $0 })
        .animation(.spring(response: 0.32, dampingFraction: 0.88), value: model.showHistory)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 560)
    }
}

private struct TitleBar: View {
    @EnvironmentObject private var model: AppModel
    let height: CGFloat

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 4) {
                Spacer().frame(width: 72)  // traffic lights
                IconButton(symbol: "sidebar.left", help: "History (⇧⌘H)", action: model.toggleHistory)
                IconButton(symbol: "plus", help: "New Scratch (⌘N)", action: model.newScratch)
                Spacer()
                IconButton(symbol: "questionmark.circle", help: "Quick Reference (⇧⌘/)", action: model.toggleReference)
                    .popover(isPresented: $model.showReference, arrowEdge: .bottom) {
                        ReferencePopover().environmentObject(model)
                    }
                FloatToggle()
                    .padding(.trailing, 6)
                StatusIndicator(state: model.kernelState)
                    .padding(.trailing, 10)
                RunButton()
            }
            .padding(.horizontal, 10)
            HStack(spacing: 6) {
                Text("Python Calculator").fontWeight(.semibold).foregroundStyle(Color.textPrimary)
                Text("—  scratch.py").foregroundStyle(Color.textSecondary)
            }
            .font(.system(size: 13))
            .allowsHitTesting(false)
        }
        .frame(height: height)
        .background(Color(Theme.chrome))
        .overlay(alignment: .bottom) { Color.hairline.frame(height: 1) }
    }
}

/// Pin button: keeps the window above all other windows.
private struct FloatToggle: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    var body: some View {
        Button(action: model.toggleFloatOnTop) {
            Image(systemName: model.floatsOnTop ? "pin.fill" : "pin")
                .font(.system(size: 12, weight: .medium))
                .rotationEffect(.degrees(model.floatsOnTop ? 0 : 45))
                .foregroundStyle(model.floatsOnTop ? Color.citrine : (hovering ? Color.textPrimary : Color.textSecondary))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.floatsOnTop ? Color.citrine.opacity(0.14) : Color.white.opacity(hovering ? 0.07 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.floatsOnTop)
        .help(model.floatsOnTop ? "Stop Floating on Top (⌥⌘T)" : "Float on Top of Other Windows (⌥⌘T)")
        .accessibilityLabel("Float on top")
        .accessibilityValue(model.floatsOnTop ? "On" : "Off")
    }
}

private struct StatusIndicator: View {
    let state: KernelState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.8), radius: 4)
                .opacity(isRunning && pulse ? 0.35 : 1)
                .animation(isRunning ? .easeInOut(duration: 0.6).repeatForever() : .default, value: pulse)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
        .onChange(of: isRunning, initial: true) { _, running in pulse = running }
        .help(help)
    }

    private var isRunning: Bool { state == .running }

    private var color: Color {
        switch state {
        case .ready: return .mint
        case .running: return .citrine
        case .starting: return .textTertiary
        case .failed: return .coral
        }
    }

    private var label: String {
        switch state {
        case .ready: return "Python ready"
        case .running: return "Running…"
        case .starting: return "Starting Python…"
        case .failed: return "Python unavailable"
        }
    }

    private var help: String {
        switch state {
        case .ready(let version): return "Python \(version)"
        case .failed(let message): return message
        default: return label
        }
    }
}

private struct RunButton: View {
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let running = model.isRunning
        Button { if running { model.stop() } else { model.run() } } label: {
            HStack(spacing: 8) {
                Image(systemName: running ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(running ? "Stop" : "Run")
                    .font(.system(size: 13, weight: .semibold))
                Keycap(keys: running ? "⌘." : "⌘↵",
                       tint: running ? .textPrimary : Color.black.opacity(0.65),
                       fill: running ? Color.white.opacity(0.1) : Color.black.opacity(0.12))
            }
            .foregroundStyle(running ? Color.textPrimary : Color(NSColor(hex: 0x1B1A10)))
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(height: 27)
            .background(Capsule(style: .continuous).fill(running ? Color.plum : Color.citrine))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(running ? 0.12 : 0.25), lineWidth: 0.5))
            .shadow(color: (running ? Color.lavender : Color.citrine).opacity(hovering ? 0.55 : 0.32), radius: hovering ? 12 : 8)
            .brightness(hovering ? 0.04 : 0)
            .scaleEffect(pressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pressed)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: running)
        .help(running ? "Stop (⌘.)" : "Run (⌘↵)")
    }
}

private struct EditorPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.citrine)
                        .frame(width: 8, height: 8)
                    Text("scratch.py")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
                    .fill(Color(Theme.editor)))
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
                    .strokeBorder(Color.hairline, lineWidth: 1).mask(Rectangle().padding(.bottom, 1)))
                Spacer()
            }
            .padding(.leading, 10)
            .padding(.top, 6)
            .frame(height: 36, alignment: .bottom)
            .background(Color(Theme.chrome))
            .overlay(alignment: .bottom) { Color.hairline.frame(height: 1) }
            CodeEditorView(controller: model.editor, onSnippet: model.insertPrint)
        }
    }
}

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var status: EditorStatus

    var body: some View {
        HStack(spacing: 10) {
            Text("Ln \(status.line), Col \(status.column)")
            dot
            Text(model.pythonLabel)
                .help(model.pythonExecutable.isEmpty ? "Python interpreter" : "Interpreter: \(model.pythonExecutable)")
            dot
            Text("Spaces: 4")
            dot
            StatusToggle(title: model.usesDegrees ? "DEG" : "RAD", isOn: model.usesDegrees,
                         help: "Angle unit for sin, cos, tan… (⌥⌘D)", action: model.toggleDegrees)
            StatusToggle(title: "LIVE", isOn: model.liveMode,
                         help: "Run automatically as you type (⌥⌘L)", action: model.toggleLiveMode)
            Spacer()
            hint("⌘↵", "Run")
            hint("⇧P", "print()")
            hint("⌘/", "Comment")
            hint("⇧⌘H", "History")
        }
        .font(.system(size: 11))
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(Theme.chrome))
        .overlay(alignment: .top) { Color.hairline.frame(height: 1) }
    }

    private struct StatusToggle: View {
        let title: String
        let isOn: Bool
        let help: String
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isOn ? Color.citrine : Color.textTertiary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .shadow(color: isOn ? Color.citrine.opacity(0.8) : .clear, radius: 3)
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isOn ? Color.textPrimary : Color.textSecondary)
                }
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(Color.textTertiary)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Keycap(keys: keys)
            Text(label)
        }
        .padding(.leading, 8)
    }
}
