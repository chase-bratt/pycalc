import Foundation
import PyCalcCore

/// SwiftUI-facing handle on the AppKit graph view.
@MainActor
final class GraphController: ObservableObject {
    typealias Sampler = (Double, Double, Int, [String]) async -> SampleSet?

    @Published private(set) var xRangeLabel = ""

    weak var view: GraphCanvasView? {
        didSet { view?.load(plots: plots, window: window, generation: generation) }
    }
    var sampler: Sampler?
    /// Called by the graph's "Show All Plots" menu item.
    var onShowAll: (() -> Void)?
    var onCopy: ((String) -> Void)?
    var onToast: ((String) -> Void)?
    var hidden: Set<String> = [] {
        didSet { view?.hiddenPlots = hidden }
    }

    private var plots: [PlotItem] = []
    private var window: [Double]?
    private var generation = 0

    func load(plots: [PlotItem], window: [Double]?, generation: Int) {
        self.plots = plots
        self.window = window
        self.generation = generation
        hidden = []
        view?.load(plots: plots, window: window, generation: generation)
    }

    func zoomIn() { view?.animateZoom(by: 2) }
    func zoomOut() { view?.animateZoom(by: 0.5) }
    func home() { view?.animateHome() }

    func viewportDidChange(xmin: Double, xmax: Double) {
        let label = "x \(NumberFormat.coordinate(xmin)) … \(NumberFormat.coordinate(xmax))"
        if label != xRangeLabel { xRangeLabel = label }
    }
}
