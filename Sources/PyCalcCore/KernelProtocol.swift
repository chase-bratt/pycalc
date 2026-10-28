import Foundation

/// Messages exchanged with `kernel.py`, one JSON object per line.
public enum KernelProtocol {
    public static func encodeRun(id: Int, code: String, degrees: Bool = false) throws -> Data {
        try line(["op": "run", "id": id, "code": code, "angle": degrees ? "deg" : "rad"])
    }

    public static func encodeSample(id: Int, xmin: Double, xmax: Double, n: Int, ids: [String]) throws -> Data {
        try line(["op": "sample", "id": id, "xmin": xmin, "xmax": xmax, "n": n, "ids": ids])
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }
}

/// Header fields every kernel reply carries; used to route the reply.
public struct KernelEnvelope: Decodable, Sendable {
    public let op: String
    public let id: Int?
}

public struct KernelHello: Decodable, Sendable {
    public let python: String
    public let numpy: Bool
    public let executable: String?
}

public struct KernelError: Decodable, Sendable, Equatable {
    public let type: String
    public let message: String
    public let line: Int?
    public let traceback: String
}

public enum PlotKind: String, Decodable, Sendable {
    case function, points, curve, vline
}

public struct PlotItem: Decodable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: PlotKind
    public let color: String
    public let label: String?
    /// Static geometry for `points` and `curve`; `nil` entries break a curve.
    public let points: [[Double]?]?
    public let x: Double?

    public init(id: String, kind: PlotKind, color: String, label: String?, points: [[Double]?]? = nil, x: Double? = nil) {
        self.id = id
        self.kind = kind
        self.color = color
        self.label = label
        self.points = points
        self.x = x
    }
}

/// Another rendering of the result, e.g. ("fraction", "3/4").
public struct AlternateForm: Decodable, Sendable, Equatable, Hashable {
    public let label: String
    public let text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

public struct Variable: Sendable, Equatable, Hashable {
    public let name: String
    public let value: String
}

public struct RunResult: Decodable, Sendable, Equatable {
    public let id: Int?
    public let ok: Bool
    public let stdout: String
    public let value: String?
    public let error: KernelError?
    public let plots: [PlotItem]
    public let window: [Double]?
    public let durationMs: Double
    /// Short value for each annotated line, keyed by 1-based line number.
    public let annotations: [Int: String]
    public let alternates: [AlternateForm]
    public let variables: [Variable]

    enum CodingKeys: String, CodingKey {
        case id, ok, stdout, value, error, plots, window, annotations, alternates, variables
        case durationMs = "duration_ms"
    }

    public init(id: Int?, ok: Bool, stdout: String, value: String?, error: KernelError?,
                plots: [PlotItem], window: [Double]?, durationMs: Double,
                annotations: [Int: String] = [:], alternates: [AlternateForm] = [], variables: [Variable] = []) {
        self.id = id
        self.ok = ok
        self.stdout = stdout
        self.value = value
        self.error = error
        self.plots = plots
        self.window = window
        self.durationMs = durationMs
        self.annotations = annotations
        self.alternates = alternates
        self.variables = variables
    }

    // New fields are optional so an older kernel.py still decodes.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int.self, forKey: .id)
        ok = try c.decode(Bool.self, forKey: .ok)
        stdout = try c.decode(String.self, forKey: .stdout)
        value = try c.decodeIfPresent(String.self, forKey: .value)
        error = try c.decodeIfPresent(KernelError.self, forKey: .error)
        plots = try c.decode([PlotItem].self, forKey: .plots)
        window = try c.decodeIfPresent([Double].self, forKey: .window)
        durationMs = try c.decode(Double.self, forKey: .durationMs)
        let rawAnnotations = try c.decodeIfPresent([String: String].self, forKey: .annotations) ?? [:]
        annotations = Dictionary(rawAnnotations.compactMap { key, text in Int(key).map { ($0, text) } }, uniquingKeysWith: { first, _ in first })
        alternates = try c.decodeIfPresent([AlternateForm].self, forKey: .alternates) ?? []
        let pairs = try c.decodeIfPresent([[String]].self, forKey: .variables) ?? []
        variables = pairs.compactMap { $0.count == 2 ? Variable(name: $0[0], value: $0[1]) : nil }
    }
}

/// Function samples on an evenly spaced grid from `xmin` to `xmax`.
public struct SampleSet: Decodable, Sendable, Equatable {
    public let xmin: Double
    public let xmax: Double
    public let n: Int
    public let series: [String: [Double?]]

    public init(xmin: Double, xmax: Double, n: Int, series: [String: [Double?]]) {
        self.xmin = xmin
        self.xmax = xmax
        self.n = n
        self.series = series
    }

    public func x(at index: Int) -> Double {
        n < 2 ? xmin : xmin + (xmax - xmin) * Double(index) / Double(n - 1)
    }

    /// Samples per world unit along x.
    public var density: Double { Double(n - 1) / (xmax - xmin) }

    /// Linear interpolation of a series at `x`, or nil if outside or undefined.
    public func value(of id: String, at x: Double) -> Double? {
        guard let ys = series[id], n >= 2, x >= xmin, x <= xmax else { return nil }
        let position = (x - xmin) / (xmax - xmin) * Double(n - 1)
        let lower = min(Int(position.rounded(.down)), n - 2)
        guard let y0 = ys[lower], let y1 = ys[lower + 1] else { return nil }
        let t = position - Double(lower)
        return y0 + (y1 - y0) * t
    }
}

public struct KernelFailure: Decodable, Sendable {
    public let message: String
}
