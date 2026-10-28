import CoreGraphics
import Foundation

/// A uniformly scaled window onto the plane: world point `center` sits at
/// the middle of the view and one world unit spans `scale` points.
public struct Viewport: Equatable, Sendable {
    public static let minScale = 1e-7
    public static let maxScale = 1e13
    public static let standard = Viewport(centerX: 0, centerY: 0, scale: 40)

    public var centerX: Double
    public var centerY: Double
    public var scale: Double

    public init(centerX: Double, centerY: Double, scale: Double) {
        self.centerX = centerX
        self.centerY = centerY
        self.scale = min(max(scale, Self.minScale), Self.maxScale)
    }

    /// The standard view for a given size: x spans -8…8.
    public static func home(for size: CGSize) -> Viewport {
        Viewport(centerX: 0, centerY: 0, scale: max(size.width, 1) / 16)
    }

    /// Smallest viewport containing the given world rectangle.
    public static func fitting(xmin: Double, xmax: Double, ymin: Double, ymax: Double, in size: CGSize) -> Viewport {
        let width = max(xmax - xmin, 1e-9)
        let height = max(ymax - ymin, 1e-9)
        let scale = min(Double(size.width) / width, Double(size.height) / height)
        return Viewport(centerX: (xmin + xmax) / 2, centerY: (ymin + ymax) / 2, scale: scale)
    }

    /// Screen coordinates use a top-left origin (flipped view).
    public func toScreen(x: Double, y: Double, in size: CGSize) -> CGPoint {
        CGPoint(x: Double(size.width) / 2 + (x - centerX) * scale,
                y: Double(size.height) / 2 - (y - centerY) * scale)
    }

    public func toWorld(_ point: CGPoint, in size: CGSize) -> (x: Double, y: Double) {
        (centerX + (Double(point.x) - Double(size.width) / 2) / scale,
         centerY - (Double(point.y) - Double(size.height) / 2) / scale)
    }

    public func xRange(in size: CGSize) -> ClosedRange<Double> {
        let half = Double(size.width) / 2 / scale
        return (centerX - half)...(centerX + half)
    }

    public func yRange(in size: CGSize) -> ClosedRange<Double> {
        let half = Double(size.height) / 2 / scale
        return (centerY - half)...(centerY + half)
    }

    /// Zoom by `factor` (>1 zooms in) keeping the world point under `anchor` fixed.
    public func zoomed(by factor: Double, around anchor: CGPoint, in size: CGSize) -> Viewport {
        let fixed = toWorld(anchor, in: size)
        let newScale = min(max(scale * factor, Self.minScale), Self.maxScale)
        let dx = (Double(anchor.x) - Double(size.width) / 2) / newScale
        let dy = (Double(anchor.y) - Double(size.height) / 2) / newScale
        return Viewport(centerX: fixed.x - dx, centerY: fixed.y + dy, scale: newScale)
    }

    /// Move the content by a screen-space delta (drag right moves content right).
    public func panned(byScreenDelta dx: Double, _ dy: Double) -> Viewport {
        Viewport(centerX: centerX - dx / scale, centerY: centerY + dy / scale, scale: scale)
    }

    /// Interpolates in log-scale so zoom animations feel uniform.
    public static func interpolate(_ a: Viewport, _ b: Viewport, _ t: Double) -> Viewport {
        if t <= 0 { return a }
        if t >= 1 { return b }
        let logScale = log(a.scale) + (log(b.scale) - log(a.scale)) * t
        return Viewport(centerX: a.centerX + (b.centerX - a.centerX) * t,
                        centerY: a.centerY + (b.centerY - a.centerY) * t,
                        scale: exp(logScale))
    }
}
