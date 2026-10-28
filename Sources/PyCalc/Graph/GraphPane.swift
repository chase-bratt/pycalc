import PyCalcCore
import SwiftUI

struct GraphPane: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: GraphController

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "GRAPH", detail: controller.xRangeLabel) {
                Text("Scroll to zoom · drag to pan")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
            GraphSurface(controller: controller)
                .clipped()
                .overlay(alignment: .topLeading) {
                    if !model.plots.isEmpty { Legend().padding(12) }
                }
                .overlay(alignment: .topTrailing) { ZoomControls(controller: controller).padding(12) }
                .overlay(alignment: .bottom) {
                    if model.plots.isEmpty { GraphHint().padding(.bottom, 16) }
                }
        }
    }
}

private struct GraphSurface: NSViewRepresentable {
    let controller: GraphController

    func makeNSView(context: Context) -> GraphCanvasView {
        let view = GraphCanvasView()
        view.clipsToBounds = true
        view.controller = controller
        controller.view = view
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
        view.setAccessibilityLabel("Graph of plotted functions")
        return view
    }

    func updateNSView(_ nsView: GraphCanvasView, context: Context) {}
}

private struct Legend: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.plots.enumerated()), id: \.element.id) { index, plot in
                let hidden = model.hiddenPlots.contains(plot.id)
                Button { model.togglePlot(plot.id) } label: {
                    HStack(spacing: 10) {
                        swatch(for: plot)
                            .frame(width: 16, height: 10)
                        Text(plot.label ?? fallbackLabel(plot, index: index))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: 220, alignment: .leading)
                    }
                    .opacity(hidden ? 0.35 : 1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hidden ? "Show" : "Hide")
            }
        }
        .padding(8)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Theme.chrome).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func fallbackLabel(_ plot: PlotItem, index: Int) -> String {
        switch plot.kind {
        case .function: return "f\(index + 1)(x)"
        case .points: return "points \(index + 1)"
        case .curve: return "curve \(index + 1)"
        case .vline: return "line \(index + 1)"
        }
    }

    @ViewBuilder private func swatch(for plot: PlotItem) -> some View {
        let color = Color(NSColor(hexString: plot.color))
        if plot.kind == .points {
            Circle().fill(color).frame(width: 7, height: 7)
        } else {
            Capsule().fill(color).frame(width: 16, height: 3).shadow(color: color.opacity(0.6), radius: 3)
        }
    }
}

private struct ZoomControls: View {
    let controller: GraphController

    var body: some View {
        VStack(spacing: 0) {
            IconButton(symbol: "plus", help: "Zoom In (⌘=)", size: 30, action: controller.zoomIn)
            Color.white.opacity(0.07).frame(width: 22, height: 1)
            IconButton(symbol: "minus", help: "Zoom Out (⌘-)", size: 30, action: controller.zoomOut)
            Color.white.opacity(0.07).frame(width: 22, height: 1)
            IconButton(symbol: "house", help: "Default View (⌘0)", size: 30, action: controller.home)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Theme.chrome).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.07)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }
}

private struct GraphHint: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("plot(lambda x: x**2)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.lavender.opacity(0.8))
            Text("Plot functions from your script to see them here")
                .font(.system(size: 11))
                .foregroundStyle(Color.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(Theme.chrome).opacity(0.85)))
        .allowsHitTesting(false)
    }
}
