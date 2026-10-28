import AppKit
import PyCalcCore

/// Desmos-style graph surface: scroll or pinch to zoom around the pointer,
/// drag (with momentum) to pan, hover to trace curves and read points of interest.
/// Functions are re-sampled from the live Python kernel as the view moves.
final class GraphCanvasView: NSView {
    weak var controller: GraphController?

    private(set) var viewport = Viewport.standard {
        didSet { viewportChanged() }
    }
    var hiddenPlots: Set<String> = [] { didSet { needsDisplay = true } }

    private var plots: [PlotItem] = []
    private var scriptWindow: [Double]?
    private var generation = 0
    private var samples: SampleSet?
    private var sampleGeneration = -1
    private var sampling = false
    /// The request that last failed; not retried until the view or data changes.
    private var failedRequest: (generation: Int, viewport: Viewport, size: CGSize)?
    private static let maxSamples = 8000
    private var hasLaidOut = false

    var hover: CGPoint?
    private var dragOrigin: CGPoint?
    private var dragMoved = false
    private var velocity = CGVector.zero
    private var lastDragTime: CFTimeInterval = 0
    private var pinned: [PointOfInterest] = []

    private var link: CADisplayLink?
    private var animation: Animation?

    private enum Animation {
        case inertia(CGVector, CFTimeInterval)
        case transition(from: Viewport, to: Viewport, start: CFTimeInterval)
    }

    struct Hit {
        let point: CGPoint
        let x: Double
        let y: Double
        let color: NSColor
        let title: String?
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Data

    func load(plots: [PlotItem], window: [Double]?, generation: Int) {
        self.plots = plots
        self.scriptWindow = window
        self.generation = generation
        pinned = []
        if let window = scriptWindow, window.count == 4, hasLaidOut {
            viewport = Viewport.fitting(xmin: window[0], xmax: window[1], ymin: window[2], ymax: window[3], in: plotSize)
        }
        requestSamplesIfNeeded()
        needsDisplay = true
    }

    private var functionIDs: [String] { plots.filter { $0.kind == .function }.map(\.id) }
    private var plotSize: CGSize { bounds.size }

    private func viewportChanged() {
        let range = viewport.xRange(in: plotSize)
        controller?.viewportDidChange(xmin: range.lowerBound, xmax: range.upperBound)
        requestSamplesIfNeeded()
        needsDisplay = true
    }

    private func needsSamples() -> Bool {
        guard !functionIDs.isEmpty, bounds.width > 0 else { return false }
        if let failed = failedRequest, failed.generation == generation, failed.viewport == viewport, failed.size == plotSize {
            return false
        }
        guard let samples, sampleGeneration == generation else { return true }
        let range = viewport.xRange(in: plotSize)
        // Never demand more density than a capped request can deliver.
        let achievable = Double(Self.maxSamples - 1) / (3 * (range.upperBound - range.lowerBound))
        return samples.xmin > range.lowerBound || samples.xmax < range.upperBound
            || samples.density < min(viewport.scale * 0.6, achievable * 0.95)
    }

    private func requestSamplesIfNeeded() {
        guard !sampling, needsSamples(), let sampler = controller?.sampler else { return }
        let range = viewport.xRange(in: plotSize)
        let span = range.upperBound - range.lowerBound
        let count = min(Self.maxSamples, Int(bounds.width * 3 * 1.25))
        let requested = (generation: generation, viewport: viewport, size: plotSize)
        sampling = true
        Task { @MainActor [weak self] in
            let result = await sampler(range.lowerBound - span, range.upperBound + span, count, self?.functionIDs ?? [])
            guard let self else { return }
            sampling = false
            if let result {
                failedRequest = nil
                if requested.generation == generation {
                    samples = result
                    sampleGeneration = requested.generation
                    needsDisplay = true
                }
            } else {
                failedRequest = requested
            }
            requestSamplesIfNeeded()
        }
    }

    // MARK: - Layout

    override func setFrameSize(_ newSize: NSSize) {
        let old = bounds.size
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        if !hasLaidOut {
            hasLaidOut = true
            if let window = scriptWindow, window.count == 4 {
                viewport = Viewport.fitting(xmin: window[0], xmax: window[1], ymin: window[2], ymax: window[3], in: newSize)
            } else {
                viewport = Viewport.home(for: newSize)
            }
        } else if old != newSize {
            viewportChanged()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    // MARK: - Input

    override func scrollWheel(with event: NSEvent) {
        stopAnimation()
        var delta = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { delta = -delta }
        guard delta != 0 else { return }
        let sensitivity = event.hasPreciseScrollingDeltas ? 0.008 : 0.06
        let factor = min(max(exp(Double(delta) * sensitivity), 0.7), 1.45)
        viewport = viewport.zoomed(by: factor, around: convert(event.locationInWindow, from: nil), in: plotSize)
    }

    override func magnify(with event: NSEvent) {
        stopAnimation()
        viewport = viewport.zoomed(by: 1 + Double(event.magnification),
                                   around: convert(event.locationInWindow, from: nil), in: plotSize)
    }

    override func smartMagnify(with event: NSEvent) {
        animateHome()
    }

    override func mouseDown(with event: NSEvent) {
        stopAnimation()
        window?.makeFirstResponder(self)
        let location = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2 {
            dragOrigin = nil
            animate(to: viewport.zoomed(by: 2, around: location, in: plotSize))
            return
        }
        dragOrigin = location
        dragMoved = false
        velocity = .zero
        lastDragTime = event.timestamp
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        let dx = event.deltaX, dy = event.deltaY
        dragMoved = dragMoved || abs(dx) + abs(dy) > 0.5
        viewport = viewport.panned(byScreenDelta: Double(dx), Double(dy))
        let dt = max(event.timestamp - lastDragTime, 1.0 / 240)
        let instant = CGVector(dx: dx / dt, dy: dy / dt)
        velocity = CGVector(dx: velocity.dx * 0.4 + instant.dx * 0.6, dy: velocity.dy * 0.4 + instant.dy * 0.6)
        lastDragTime = event.timestamp
        hover = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragOrigin != nil else { return }
        NSCursor.pop()
        defer { dragOrigin = nil }
        let location = convert(event.locationInWindow, from: nil)
        if !dragMoved {
            togglePin(near: location)
            return
        }
        let idle = event.timestamp - lastDragTime
        let speed = hypot(velocity.dx, velocity.dy)
        if idle < 0.05, speed > 120 {
            startAnimation(.inertia(velocity, CACurrentMediaTime()))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        hover = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hover = nil
        needsDisplay = true
    }

    private func togglePin(near location: CGPoint) {
        guard let poi = nearestPOI(to: location) else { return }
        if let index = pinned.firstIndex(of: poi) { pinned.remove(at: index) } else { pinned.append(poi) }
        needsDisplay = true
    }

    // MARK: - Animation

    func animateZoom(by factor: Double) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let base = targetViewport ?? viewport
        animate(to: base.zoomed(by: factor, around: center, in: plotSize))
    }

    func animateHome() {
        if let window = scriptWindow, window.count == 4 {
            animate(to: Viewport.fitting(xmin: window[0], xmax: window[1], ymin: window[2], ymax: window[3], in: plotSize))
        } else {
            animate(to: Viewport.home(for: plotSize))
        }
    }

    private var targetViewport: Viewport? {
        if case .transition(_, let target, _) = animation { return target }
        return nil
    }

    private func animate(to target: Viewport) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopAnimation()
            viewport = target
            return
        }
        startAnimation(.transition(from: viewport, to: target, start: CACurrentMediaTime()))
    }

    private func startAnimation(_ next: Animation) {
        animation = next
        if link == nil {
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    private func stopAnimation() {
        animation = nil
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        switch animation {
        case .inertia(let initial, let start):
            // Exponential decay matching the system scroll deceleration (~0.998 per ms).
            let t = now - start
            let decay = pow(0.998, t * 1000)
            let current = CGVector(dx: initial.dx * decay, dy: initial.dy * decay)
            guard hypot(current.dx, current.dy) > 8 else { return stopAnimation() }
            let frame = link.targetTimestamp - link.timestamp
            viewport = viewport.panned(byScreenDelta: Double(current.dx * frame), Double(current.dy * frame))
        case .transition(let from, let to, let start):
            // Critically damped spring step response (response ≈ 0.38 s).
            let omega = 2 * Double.pi / 0.38
            let t = now - start
            let progress = 1 - (1 + omega * t) * exp(-omega * t)
            if progress > 0.999 {
                viewport = to
                stopAnimation()
            } else {
                viewport = Viewport.interpolate(from, to, progress)
            }
        case nil:
            stopAnimation()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.graph.setFill()
        bounds.fill()
        drawGrid(context)
        let geometry = visibleFunctionGeometry()
        for plot in plots where !hiddenPlots.contains(plot.id) {
            drawPlot(plot, geometry: geometry, in: context)
        }
        let pois = pointsOfInterest(geometry)
        drawPOIs(pois, in: context)
        drawHover(geometry: geometry, pois: pois, in: context)
        drawPinned(in: context)
    }

    private func drawGrid(_ context: CGContext) {
        let size = plotSize
        let spacing = GridSpacing.forScale(viewport.scale)
        let xs = viewport.xRange(in: size), ys = viewport.yRange(in: size)

        func strokeLines(step: Double, color: NSColor) {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1)
            for x in GridSpacing.ticks(in: xs, step: step) {
                let px = pixelAlign(viewport.toScreen(x: x, y: 0, in: size).x)
                context.move(to: CGPoint(x: px, y: 0)); context.addLine(to: CGPoint(x: px, y: size.height))
            }
            for y in GridSpacing.ticks(in: ys, step: step) {
                let py = pixelAlign(viewport.toScreen(x: 0, y: y, in: size).y)
                context.move(to: CGPoint(x: 0, y: py)); context.addLine(to: CGPoint(x: size.width, y: py))
            }
            context.strokePath()
        }
        strokeLines(step: spacing.minor, color: NSColor(white: 1, alpha: 0.028))
        strokeLines(step: spacing.major, color: NSColor(white: 1, alpha: 0.075))

        let origin = viewport.toScreen(x: 0, y: 0, in: size)
        context.setStrokeColor(NSColor(white: 1, alpha: 0.42).cgColor)
        context.setLineWidth(1.2)
        if origin.x >= 0, origin.x <= size.width {
            context.move(to: CGPoint(x: pixelAlign(origin.x), y: 0)); context.addLine(to: CGPoint(x: pixelAlign(origin.x), y: size.height))
        }
        if origin.y >= 0, origin.y <= size.height {
            context.move(to: CGPoint(x: 0, y: pixelAlign(origin.y))); context.addLine(to: CGPoint(x: size.width, y: pixelAlign(origin.y)))
        }
        context.strokePath()
        drawTickLabels(spacing: spacing, origin: origin)
    }

    private func drawTickLabels(spacing: GridSpacing, origin: CGPoint) {
        let size = plotSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Theme.secondaryText.withAlphaComponent(0.85),
        ]
        // Labels stick to the nearest edge when the axis scrolls out of view.
        let labelY = min(max(origin.y + 5, 4), size.height - 16)
        for x in GridSpacing.ticks(in: viewport.xRange(in: size), step: spacing.major) where x != 0 {
            let text = NumberFormat.tick(x, step: spacing.major) as NSString
            let width = text.size(withAttributes: attributes).width
            let px = viewport.toScreen(x: x, y: 0, in: size).x
            drawHalo(text, at: CGPoint(x: px - width / 2, y: labelY), attributes: attributes)
        }
        for y in GridSpacing.ticks(in: viewport.yRange(in: size), step: spacing.major) where y != 0 {
            let text = NumberFormat.tick(y, step: spacing.major) as NSString
            let width = text.size(withAttributes: attributes).width
            let labelX = min(max(origin.x - width - 6, 4), size.width - width - 4)
            let py = viewport.toScreen(x: 0, y: y, in: size).y
            drawHalo(text, at: CGPoint(x: labelX, y: py - 7), attributes: attributes)
        }
        if origin.x > 0, origin.x < size.width, origin.y > 0, origin.y < size.height {
            drawHalo("0", at: CGPoint(x: origin.x - 12, y: origin.y + 5), attributes: attributes)
        }
    }

    private func drawHalo(_ text: NSString, at point: CGPoint, attributes: [NSAttributedString.Key: Any]) {
        var halo = attributes
        halo[.foregroundColor] = Theme.graph
        halo[.strokeColor] = Theme.graph
        halo[.strokeWidth] = 6
        text.draw(at: point, withAttributes: halo)
        text.draw(at: point, withAttributes: attributes)
    }

    private func pixelAlign(_ value: CGFloat) -> CGFloat { (value.rounded(.down)) + 0.5 }

    /// Visible slice of each function's samples, shared by drawing, POIs and hit testing.
    struct FunctionGeometry {
        let id: String
        let color: NSColor
        let xs: [Double]
        let ys: [Double?]
    }

    private var jumpLimit: Double {
        let range = viewport.yRange(in: plotSize)
        return range.upperBound - range.lowerBound
    }

    func visibleFunctionGeometry() -> [FunctionGeometry] {
        guard let samples, sampleGeneration == generation, samples.n >= 2 else { return [] }
        let range = viewport.xRange(in: plotSize)
        guard range.upperBound > samples.xmin, range.lowerBound < samples.xmax else { return [] }
        let step = (samples.xmax - samples.xmin) / Double(samples.n - 1)
        let top = Double(samples.n - 1)
        // Clamp in floating point: stale samples can be astronomically far from the view.
        let lower = min(max(((range.lowerBound - samples.xmin) / step).rounded(.down) - 1, 0), top)
        let upper = min(max(((range.upperBound - samples.xmin) / step).rounded(.up) + 1, 0), top)
        let first = Int(lower), last = Int(upper)
        guard first < last else { return [] }
        let xs = (first...last).map(samples.x(at:))
        return plots.compactMap { plot in
            guard plot.kind == .function, !hiddenPlots.contains(plot.id), let ys = samples.series[plot.id] else { return nil }
            return FunctionGeometry(id: plot.id, color: NSColor(hexString: plot.color), xs: xs, ys: Array(ys[first...last]))
        }
    }

    private func drawPlot(_ plot: PlotItem, geometry: [FunctionGeometry], in context: CGContext) {
        let color = NSColor(hexString: plot.color)
        let size = plotSize
        switch plot.kind {
        case .function:
            guard let curve = geometry.first(where: { $0.id == plot.id }) else { return }
            let runs = CurveAnalysis.segments(xs: curve.xs, ys: curve.ys, jumpLimit: jumpLimit)
            strokeGlowing(runs.map { $0.map { screenPoint($0.x, $0.y) } }, color: color, in: context)
        case .curve:
            var runs: [[CGPoint]] = [[]]
            for entry in plot.points ?? [] {
                if let entry, entry.count == 2 { runs[runs.count - 1].append(screenPoint(entry[0], entry[1])) }
                else if !(runs.last?.isEmpty ?? true) { runs.append([]) }
            }
            strokeGlowing(runs, color: color, in: context)
        case .vline:
            guard let x = plot.x else { return }
            let px = viewport.toScreen(x: x, y: 0, in: size).x
            strokeGlowing([[CGPoint(x: px, y: 0), CGPoint(x: px, y: size.height)]], color: color, in: context)
        case .points:
            for entry in plot.points ?? [] {
                guard let entry, entry.count == 2 else { continue }
                let p = screenPoint(entry[0], entry[1])
                guard bounds.insetBy(dx: -10, dy: -10).contains(p) else { continue }
                context.saveGState()
                context.setShadow(offset: .zero, blur: 8, color: color.withAlphaComponent(0.6).cgColor)
                context.setFillColor(color.cgColor)
                context.fillEllipse(in: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9))
                context.restoreGState()
                if let label = plot.label, (plot.points?.count ?? 0) == 1 {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color,
                    ]
                    drawHalo(label as NSString, at: CGPoint(x: p.x + 8, y: p.y - 18), attributes: attributes)
                }
            }
        }
    }

    private func screenPoint(_ x: Double, _ y: Double) -> CGPoint {
        let p = viewport.toScreen(x: x, y: y, in: plotSize)
        // Clamp far-off points so CoreGraphics never sees huge coordinates.
        return CGPoint(x: min(max(p.x, -20_000), 20_000), y: min(max(p.y, -20_000), 20_000))
    }

    private func strokeGlowing(_ runs: [[CGPoint]], color: NSColor, in context: CGContext) {
        let path = CGMutablePath()
        for run in runs where run.count > 1 {
            path.move(to: run[0])
            run.dropFirst().forEach { path.addLine(to: $0) }
        }
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 7, color: color.withAlphaComponent(0.55).cgColor)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2.4)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    // MARK: - Points of interest & hover

    private func pointsOfInterest(_ geometry: [FunctionGeometry]) -> [PointOfInterest] {
        var found: [PointOfInterest] = []
        for curve in geometry {
            found += CurveAnalysis.pointsOfInterest(xs: curve.xs, ys: curve.ys, jumpLimit: jumpLimit)
        }
        for i in geometry.indices {
            for j in geometry.indices where j > i {
                found += CurveAnalysis.intersections(xs: geometry[i].xs, geometry[i].ys, geometry[j].ys, jumpLimit: jumpLimit)
            }
        }
        let visible = bounds.insetBy(dx: -4, dy: -4)
        return found.filter { visible.contains(screenPoint($0.x, $0.y)) }
    }

    private func drawPOIs(_ pois: [PointOfInterest], in context: CGContext) {
        context.setLineWidth(1.5)
        for poi in pois {
            let p = screenPoint(poi.x, poi.y)
            let dot = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            context.setFillColor(NSColor(hex: 0x8C8996).cgColor)
            context.setStrokeColor(NSColor(hex: 0x141417).cgColor)
            context.fillEllipse(in: dot)
            context.strokeEllipse(in: dot)
        }
    }

    func nearestPOI(to location: CGPoint) -> PointOfInterest? {
        let candidates = pointsOfInterest(visibleFunctionGeometry())
        return candidates
            .map { ($0, hypot(screenPoint($0.x, $0.y).x - location.x, screenPoint($0.x, $0.y).y - location.y)) }
            .filter { $0.1 < 9 }
            .min { $0.1 < $1.1 }?.0
    }

    private func drawHover(geometry: [FunctionGeometry], pois: [PointOfInterest], in context: CGContext) {
        guard let hover, dragOrigin == nil || !dragMoved else { return }
        if let poi = nearestPOI(to: hover) {
            let p = screenPoint(poi.x, poi.y)
            drawMarker(at: p, color: Theme.text, in: context)
            drawBubble(title: poi.kind.title, x: poi.x, y: poi.y, at: p, color: Theme.text)
            return
        }
        guard let hit = hitTest(hover, geometry: geometry) else { return }
        drawMarker(at: hit.point, color: hit.color, in: context)
        drawBubble(title: hit.title, x: hit.x, y: hit.y, at: hit.point, color: hit.color)
    }

    func hitTest(_ location: CGPoint, geometry: [FunctionGeometry]) -> Hit? {
        let world = viewport.toWorld(location, in: plotSize)
        var best: (Hit, CGFloat)?
        func consider(_ hit: Hit) {
            let distance = hypot(hit.point.x - location.x, hit.point.y - location.y)
            if distance < 12, distance < (best?.1 ?? .infinity) { best = (hit, distance) }
        }
        for plot in plots where !hiddenPlots.contains(plot.id) {
            let color = NSColor(hexString: plot.color)
            switch plot.kind {
            case .function:
                if let y = samples?.value(of: plot.id, at: world.x), sampleGeneration == generation {
                    consider(Hit(point: screenPoint(world.x, y), x: world.x, y: y, color: color, title: plot.label))
                }
            case .points, .curve:
                for entry in plot.points ?? [] {
                    guard let entry, entry.count == 2 else { continue }
                    consider(Hit(point: screenPoint(entry[0], entry[1]), x: entry[0], y: entry[1], color: color, title: plot.label))
                }
            case .vline:
                if let x = plot.x {
                    consider(Hit(point: screenPoint(x, world.y), x: x, y: world.y, color: color, title: plot.label))
                }
            }
        }
        return best?.0
    }

    private func drawPinned(in context: CGContext) {
        for poi in pinned {
            let p = screenPoint(poi.x, poi.y)
            guard bounds.contains(p) else { continue }
            drawMarker(at: p, color: Theme.text, in: context)
            drawBubble(title: poi.kind.title, x: poi.x, y: poi.y, at: p, color: Theme.text)
        }
    }

    private func drawMarker(at point: CGPoint, color: NSColor, in context: CGContext) {
        let ring = CGRect(x: point.x - 5.5, y: point.y - 5.5, width: 11, height: 11)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 10, color: color.withAlphaComponent(0.7).cgColor)
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: ring)
        context.restoreGState()
        context.setStrokeColor(Theme.graph.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: ring)
    }

    private func drawBubble(title: String?, x: Double, y: Double, at point: CGPoint, color: NSColor) {
        let coordinates = "(\(NumberFormat.coordinate(x)), \(NumberFormat.coordinate(y)))"
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let text = NSMutableAttributedString(string: coordinates, attributes: [.font: font, .foregroundColor: Theme.text])
        if let title {
            text.insert(NSAttributedString(string: title + "  ", attributes: [.font: font, .foregroundColor: color]), at: 0)
        }
        let size = text.size()
        var frame = CGRect(x: point.x + 12, y: point.y - size.height - 16, width: size.width + 18, height: size.height + 10)
        if frame.maxX > bounds.maxX - 6 { frame.origin.x = point.x - frame.width - 12 }
        if frame.minY < 6 { frame.origin.y = point.y + 12 }
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(hex: 0x25252B, alpha: 0.96).setFill()
        path.fill()
        Theme.hairline.setStroke()
        path.lineWidth = 1
        path.stroke()
        text.draw(at: CGPoint(x: frame.minX + 9, y: frame.minY + 5))
    }
}

private extension PointOfInterest.Kind {
    var title: String {
        switch self {
        case .root: return "root"
        case .minimum: return "min"
        case .maximum: return "max"
        case .intercept: return "y-int"
        case .intersection: return "intersect"
        }
    }
}
