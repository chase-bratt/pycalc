import Foundation

/// A notable point on a function graph: a root, extremum or y-intercept.
public struct PointOfInterest: Equatable, Sendable {
    public enum Kind: String, Sendable { case root, minimum, maximum, intercept, intersection }

    public let kind: Kind
    public let x: Double
    public let y: Double

    public init(kind: Kind, x: Double, y: Double) {
        self.kind = kind
        self.x = x
        self.y = y
    }
}

public enum CurveAnalysis {
    /// Splits samples into continuous runs. A run breaks at undefined values
    /// and at jumps larger than `jumpLimit` (vertical asymptotes such as tan).
    public static func segments(xs: [Double], ys: [Double?], jumpLimit: Double) -> [[(x: Double, y: Double)]] {
        var runs: [[(x: Double, y: Double)]] = []
        var current: [(x: Double, y: Double)] = []
        for (x, value) in zip(xs, ys) {
            guard let y = value, y.isFinite else {
                if !current.isEmpty { runs.append(current); current = [] }
                continue
            }
            if let previous = current.last, abs(y - previous.y) > jumpLimit {
                runs.append(current)
                current = []
            }
            current.append((x, y))
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// Roots, local extrema and the y-intercept found in sampled data.
    /// Returns nothing when the curve is too busy to annotate usefully.
    public static func pointsOfInterest(xs: [Double], ys: [Double?], jumpLimit: Double, limit: Int = 40) -> [PointOfInterest] {
        var found: [PointOfInterest] = []
        for run in segments(xs: xs, ys: ys, jumpLimit: jumpLimit) {
            found += roots(in: run) + extrema(in: run)
            if found.count > limit { return [] }
        }
        if let intercept = intercept(xs: xs, ys: ys) { found.append(intercept) }
        return found
    }

    /// Crossings of two functions sampled on the same x grid.
    public static func intersections(xs: [Double], _ a: [Double?], _ b: [Double?], jumpLimit: Double, limit: Int = 40) -> [PointOfInterest] {
        var found: [PointOfInterest] = []
        let count = min(xs.count, a.count, b.count)
        guard count >= 2 else { return [] }
        for i in 1..<count {
            guard let a0 = a[i - 1], let a1 = a[i], let b0 = b[i - 1], let b1 = b[i],
                  abs(a1 - a0) <= jumpLimit, abs(b1 - b0) <= jumpLimit else { continue }
            let d0 = a0 - b0, d1 = a1 - b1
            guard d1 != 0, d0 == 0 || (d0 < 0) != (d1 < 0) else { continue }
            let t = d0 == 0 ? 0 : d0 / (d0 - d1)
            found.append(.init(kind: .intersection, x: xs[i - 1] + (xs[i] - xs[i - 1]) * t, y: a0 + (a1 - a0) * t))
            if found.count > limit { return [] }
        }
        return found
    }

    static func roots(in run: [(x: Double, y: Double)]) -> [PointOfInterest] {
        guard run.count >= 2 else { return [] }
        var roots: [PointOfInterest] = []
        for i in 1..<run.count {
            let (a, b) = (run[i - 1], run[i])
            if a.y == 0 {
                // Count an exact zero once: skip when the previous sample was also zero.
                if i == 1 || run[i - 2].y != 0 { roots.append(.init(kind: .root, x: a.x, y: 0)) }
            } else if b.y != 0, (a.y < 0) != (b.y < 0) {
                let x = a.x - a.y * (b.x - a.x) / (b.y - a.y)
                roots.append(.init(kind: .root, x: x, y: 0))
            }
        }
        if let last = run.last, last.y == 0, run.count >= 2, run[run.count - 2].y != 0 {
            roots.append(.init(kind: .root, x: last.x, y: 0))
        }
        return roots
    }

    static func extrema(in run: [(x: Double, y: Double)]) -> [PointOfInterest] {
        guard run.count >= 3 else { return [] }
        var result: [PointOfInterest] = []
        for i in 1..<(run.count - 1) {
            let (a, b, c) = (run[i - 1], run[i], run[i + 1])
            let isMax = b.y > a.y && b.y >= c.y
            let isMin = b.y < a.y && b.y <= c.y
            guard isMax || isMin else { continue }
            // Refine with the vertex of the parabola through the three samples.
            let h = b.x - a.x
            let denominator = a.y - 2 * b.y + c.y
            let offset = denominator == 0 ? 0 : h * (a.y - c.y) / (2 * denominator)
            let x = b.x + max(-h, min(h, offset))
            let y = denominator == 0 ? b.y : b.y - (a.y - c.y) * offset / (4 * h)
            result.append(.init(kind: isMax ? .maximum : .minimum, x: x, y: y))
        }
        return result
    }

    static func intercept(xs: [Double], ys: [Double?]) -> PointOfInterest? {
        guard let upper = xs.firstIndex(where: { $0 >= 0 }) else { return nil }
        if xs[upper] == 0, let y = ys[upper] { return .init(kind: .intercept, x: 0, y: y) }
        guard upper > 0, let y0 = ys[upper - 1], let y1 = ys[upper] else { return nil }
        let t = (0 - xs[upper - 1]) / (xs[upper] - xs[upper - 1])
        return .init(kind: .intercept, x: 0, y: y0 + (y1 - y0) * t)
    }
}
