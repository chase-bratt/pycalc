import CoreGraphics
import Foundation
import Testing
@testable import PyCalcCore

@Suite struct ViewportTests {
    let size = CGSize(width: 400, height: 200)

    @Test func screenRoundTrip() {
        let viewport = Viewport(centerX: 3, centerY: -2, scale: 25)
        let screen = viewport.toScreen(x: 5, y: 1, in: size)
        let world = viewport.toWorld(screen, in: size)
        #expect(abs(world.x - 5) < 1e-9 && abs(world.y - 1) < 1e-9)
    }

    @Test func centerMapsToMiddleOfView() {
        #expect(Viewport(centerX: 7, centerY: 7, scale: 10).toScreen(x: 7, y: 7, in: size) == CGPoint(x: 200, y: 100))
    }

    @Test func zoomKeepsAnchorFixed() {
        let viewport = Viewport.standard
        let anchor = CGPoint(x: 300, y: 50)
        let before = viewport.toWorld(anchor, in: size)
        let after = viewport.zoomed(by: 3, around: anchor, in: size).toWorld(anchor, in: size)
        #expect(abs(before.x - after.x) < 1e-9 && abs(before.y - after.y) < 1e-9)
    }

    @Test func scaleIsClamped() {
        #expect(Viewport(centerX: 0, centerY: 0, scale: 1e30).scale == Viewport.maxScale)
        #expect(Viewport(centerX: 0, centerY: 0, scale: 0).scale == Viewport.minScale)
    }

    @Test func panMovesContentWithPointer() {
        let moved = Viewport.standard.panned(byScreenDelta: 40, 40)
        #expect(moved.centerX == -1 && moved.centerY == 1)
    }

    @Test func fittingContainsRectangle() {
        let viewport = Viewport.fitting(xmin: -1, xmax: 3, ymin: 0, ymax: 10, in: size)
        #expect(viewport.xRange(in: size).contains(-1) && viewport.xRange(in: size).contains(3))
        #expect(viewport.yRange(in: size).contains(0) && viewport.yRange(in: size).contains(10))
    }

    @Test func homeSpansSixteenUnits() {
        let width = Viewport.home(for: size).xRange(in: size)
        #expect(abs(width.upperBound - width.lowerBound - 16) < 1e-9)
    }

    @Test func interpolationEndpoints() {
        let a = Viewport(centerX: 0, centerY: 0, scale: 10)
        let b = Viewport(centerX: 10, centerY: 4, scale: 1000)
        #expect(Viewport.interpolate(a, b, 0) == a)
        #expect(abs(Viewport.interpolate(a, b, 0.5).scale - 100) < 1e-6)
    }
}

@Suite struct GridTests {
    @Test(arguments: [(40.0, 5.0, 1.0), (100.0, 1.0, 0.2), (30.0, 5.0, 1.0), (1.0, 100.0, 20.0)])
    func spacingFollowsOneTwoFive(scale: Double, major: Double, minor: Double) {
        let spacing = GridSpacing.forScale(scale)
        #expect(abs(spacing.major - major) < 1e-9)
        #expect(abs(spacing.minor - minor) < 1e-9)
    }

    @Test func twoStepUsesQuarters() {
        let spacing = GridSpacing.forScale(60)
        #expect(spacing.major == 2 && spacing.minor == 0.5)
    }

    @Test func ticksAreExactMultiples() {
        #expect(GridSpacing.ticks(in: -0.25...0.75, step: 0.1).count == 10)
        #expect(GridSpacing.ticks(in: 1...4, step: 2) == [2, 4])
        #expect(GridSpacing.ticks(in: 0...1e9, step: 1).isEmpty)
        #expect(GridSpacing.ticks(in: 0...1, step: 0).isEmpty)
    }

    @Test func tickLabels() {
        #expect(NumberFormat.tick(0, step: 1) == "0")
        #expect(NumberFormat.tick(2.5, step: 0.5) == "2.5")
        #expect(NumberFormat.tick(-10, step: 5) == "-10")
        #expect(NumberFormat.tick(2e6, step: 1e6) == "2×10⁶")
        #expect(NumberFormat.tick(1e-5, step: 1e-5) == "10⁻⁵")
    }

    @Test func coordinates() {
        #expect(NumberFormat.coordinate(3.14159265) == "3.1416")
        #expect(NumberFormat.coordinate(-0.000012) == "-1.2×10⁻⁵")
        #expect(NumberFormat.coordinate(.nan) == "undefined")
        #expect(NumberFormat.coordinate(0) == "0")
        #expect(NumberFormat.coordinate(1234.5) == "1234.5")
    }
}

@Suite struct CurveAnalysisTests {
    func sample(_ f: (Double) -> Double?, from lo: Double, to hi: Double, n: Int) -> ([Double], [Double?]) {
        let xs = (0..<n).map { lo + (hi - lo) * Double($0) / Double(n - 1) }
        return (xs, xs.map(f))
    }

    @Test func segmentsBreakAtUndefinedAndJumps() {
        let runs = CurveAnalysis.segments(xs: [0, 1, 2, 3, 4], ys: [1, nil, 2, 100, 101], jumpLimit: 10)
        #expect(runs.map(\.count) == [1, 1, 2])
    }

    @Test func parabolaHasMinimumRootsAndIntercept() {
        let (xs, ys) = sample({ $0 * $0 - 4 }, from: -5, to: 5, n: 401)
        let points = CurveAnalysis.pointsOfInterest(xs: xs, ys: ys, jumpLimit: 100)
        let roots = points.filter { $0.kind == .root }.map(\.x).sorted()
        #expect(roots.count == 2)
        #expect(abs(roots[0] + 2) < 1e-3 && abs(roots[1] - 2) < 1e-3)
        let minimum = points.first { $0.kind == .minimum }
        #expect(minimum.map { abs($0.x) < 1e-6 && abs($0.y + 4) < 1e-6 } == true)
        #expect(points.contains { $0.kind == .intercept && abs($0.y + 4) < 1e-9 })
    }

    @Test func exactZeroCountedOnce() {
        let roots = CurveAnalysis.roots(in: [(-1, -1), (0, 0), (1, 1)])
        #expect(roots == [PointOfInterest(kind: .root, x: 0, y: 0)])
    }

    @Test func asymptoteIsNotARoot() {
        let (xs, ys) = sample({ 1 / $0 }, from: -1.05, to: 1, n: 40)
        let points = CurveAnalysis.pointsOfInterest(xs: xs, ys: ys, jumpLimit: 5)
        #expect(!points.contains { $0.kind == .root })
    }

    @Test func busyCurveIsNotAnnotated() {
        let (xs, ys) = sample({ sin($0) }, from: -500, to: 500, n: 8000)
        #expect(CurveAnalysis.pointsOfInterest(xs: xs, ys: ys, jumpLimit: 10).isEmpty)
    }

    @Test func intersectionsOfLineAndParabola() {
        let (xs, a) = sample({ $0 * $0 }, from: -3, to: 3, n: 601)
        let (_, b) = sample({ $0 + 2 }, from: -3, to: 3, n: 601)
        let points = CurveAnalysis.intersections(xs: xs, a, b, jumpLimit: 100)
        #expect(points.count == 2)
        #expect(abs(points[0].x + 1) < 1e-3 && abs(points[1].x - 2) < 1e-3 && abs(points[1].y - 4) < 1e-2)
        #expect(CurveAnalysis.intersections(xs: [0], [1], [1], jumpLimit: 1).isEmpty)
    }

    @Test func interceptInterpolates() {
        let point = CurveAnalysis.intercept(xs: [-1, 1], ys: [0, 2])
        #expect(point == PointOfInterest(kind: .intercept, x: 0, y: 1))
        #expect(CurveAnalysis.intercept(xs: [1, 2], ys: [0, 2]) == nil)
    }
}

@Suite struct SampleSetTests {
    let samples = SampleSet(xmin: 0, xmax: 2, n: 3, series: ["p1": [0, 10, nil]])

    @Test func interpolatesBetweenSamples() {
        #expect(samples.value(of: "p1", at: 0.5) == 5)
        #expect(samples.value(of: "p1", at: 1.5) == nil)
        #expect(samples.value(of: "p1", at: 3) == nil)
        #expect(samples.value(of: "missing", at: 1) == nil)
        #expect(samples.x(at: 2) == 2 && samples.density == 1)
    }
}

@Suite struct ProtocolTests {
    @Test func decodesRunResult() throws {
        let json = """
        {"op":"result","id":3,"ok":false,"stdout":"hi\\n","value":null,
         "error":{"type":"NameError","message":"x","line":2,"traceback":"tb"},
         "plots":[{"id":"p1","kind":"curve","color":"#fff","label":null,"points":[[0,1],null]}],
         "window":[-1,1,-1,1],"duration_ms":1.5}
        """
        let result = try JSONDecoder().decode(RunResult.self, from: Data(json.utf8))
        #expect(result.error?.line == 2)
        #expect(result.plots.first?.points?.count == 2)
        #expect(result.durationMs == 1.5)
    }

    @Test func decodesCalculatorExtras() throws {
        let json = """
        {"ok":true,"stdout":"","value":"3","error":null,"plots":[],"window":null,"duration_ms":1,
         "annotations":{"2":"3","x":"skip"},"alternates":[{"label":"hex","text":"0x3"}],
         "variables":[["r","2"],["bad"]]}
        """
        let result = try JSONDecoder().decode(RunResult.self, from: Data(json.utf8))
        #expect(result.annotations == [2: "3"])
        #expect(result.alternates == [AlternateForm(label: "hex", text: "0x3")])
        #expect(result.variables.map(\.name) == ["r"])
    }

    @Test func runRequestCarriesAngleMode() throws {
        let data = try KernelProtocol.encodeRun(id: 1, code: "1", degrees: true)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        #expect(object?["angle"] as? String == "deg")
    }

    @Test func encodesRequestsAsLines() throws {
        let data = try KernelProtocol.encodeSample(id: 1, xmin: 0, xmax: 1, n: 2, ids: ["p1"])
        #expect(data.last == 0x0A)
        let object = try JSONSerialization.jsonObject(with: data.dropLast()) as? [String: Any]
        #expect(object?["op"] as? String == "sample")
        #expect(try KernelProtocol.encodeRun(id: 1, code: "1").last == 0x0A)
    }
}

@Suite struct TokenizerTests {
    func kinds(_ source: String) -> [(PythonTokenizer.Kind, String)] {
        let units = Array(source.utf16)
        return PythonTokenizer.tokenize(source).map {
            ($0.kind, String(utf16CodeUnits: Array(units[$0.location..<($0.location + $0.length)]), count: $0.length))
        }
    }

    @Test func classifiesCommonTokens() {
        let tokens = kinds("def area(r):\n    return pi * r**2  # circle")
        #expect(tokens.contains { $0 == (.keyword, "def") })
        #expect(tokens.contains { $0 == (.definition, "area") })
        #expect(tokens.contains { $0 == (.constant, "pi") })
        #expect(tokens.contains { $0 == (.number, "2") })
        #expect(tokens.contains { $0 == (.comment, "# circle") })
    }

    @Test func stringsIncludingPrefixesAndTripleQuotes() {
        let tokens = kinds("a = f\"x{1}\" + '''multi\nline''' + 'it\\'s'")
        let strings = tokens.filter { $0.0 == .string }.map(\.1)
        #expect(strings == ["f\"x{1}\"", "'''multi\nline'''", "'it\\'s'"])
    }

    @Test func numbersAndCalls() {
        let tokens = kinds("print(0x1F, 1_000.5e-3, 2j, .5)\nfoo (1)")
        #expect(tokens.filter { $0.0 == .number }.map(\.1) == ["0x1F", "1_000.5e-3", "2j", ".5", "1"])
        #expect(tokens.contains { $0 == (.builtin, "print") })
        #expect(tokens.contains { $0 == (.call, "foo") })
    }

    @Test func decoratorsAndSelf() {
        let tokens = kinds("@property\ndef f(self):\n    return self.x @ y")
        #expect(tokens.first.map { $0 == (.decorator, "@property") } == true)
        #expect(tokens.filter { $0.0 == .selfParameter }.count == 2)
        #expect(tokens.contains { $0 == (.op, "@") })
    }

    @Test func unterminatedStringStopsAtNewline() {
        let tokens = kinds("'open\nx = 1")
        #expect(tokens.first.map { $0 == (.string, "'open") } == true)
    }
}

@Suite struct HistoryTests {
    func makeStore(now: @escaping () -> Date = Date.init) throws -> HistoryStore {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("pycalc-\(UUID().uuidString).sqlite").path
        return try HistoryStore(path: path, now: now)
    }

    @Test func recordsAndListsNewestFirst() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = try makeStore { clock }
        try store.record(code: "1 + 1", summary: "2", succeeded: true)
        clock += 60
        try store.record(code: "print('b')", summary: "b", succeeded: true)
        #expect(try store.entries().map(\.code) == ["print('b')", "1 + 1"])
    }

    @Test func rerunUpdatesInsteadOfDuplicating() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = try makeStore { clock }
        try store.record(code: "x", summary: "", succeeded: false)
        clock += 10
        try store.record(code: "x", summary: "ok", succeeded: true)
        let entries = try store.entries()
        #expect(entries.count == 1)
        #expect(entries[0].succeeded && entries[0].summary == "ok" && entries[0].createdAt == clock)
    }

    @Test func expiresAfterThirtyDays() throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let store = try makeStore { clock }
        try store.record(code: "old", summary: "", succeeded: true)
        clock += 29 * 86_400
        try store.record(code: "recent", summary: "", succeeded: true)
        clock += 2 * 86_400
        try store.purgeExpired()
        #expect(try store.entries().map(\.code) == ["recent"])
    }

    @Test func searchAndDelete() throws {
        let store = try makeStore()
        let entry = try store.record(code: "Plot(sin)", summary: "", succeeded: true)
        try store.record(code: "cos", summary: "", succeeded: true)
        #expect(try store.entries(matching: "plot").count == 1)
        try store.delete(id: try #require(entry).id)
        #expect(try store.entries().map(\.code) == ["cos"])
    }

    @Test func textWithNulIsStoredWhole() throws {
        let store = try makeStore()
        try store.record(code: "a\u{0}b", summary: "", succeeded: true)
        try store.record(code: "a\u{0}c", summary: "", succeeded: true)
        #expect(try store.entries().count == 2)
        #expect(try store.entries().contains { $0.code == "a\u{0}b" })
    }

    @Test func deleteAllEmptiesHistory() throws {
        let store = try makeStore()
        try store.record(code: "1", summary: "", succeeded: true)
        try store.deleteAll()
        #expect(try store.entries().isEmpty)
    }

    @Test func blankScriptsAreIgnored() throws {
        #expect(try makeStore().record(code: "  \n", summary: "", succeeded: true) == nil)
    }

    @Test func badPathThrows() {
        #expect(throws: HistoryStoreError.self) { try HistoryStore(path: "/nonexistent/dir/db.sqlite") }
    }

    @Test func titleSkipsCommentsAndBlankLines() {
        let entry = HistoryEntry(id: 1, createdAt: Date(), code: "\n# note\n  x = 2\n", summary: "", succeeded: true)
        #expect(entry.title == "x = 2")
    }

    @Test func groupsByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let entries = [0.0, 3600, 86_400, 3 * 86_400].map {
            HistoryEntry(id: Int64($0), createdAt: now - $0, code: "c", summary: "", succeeded: true)
        }
        let sections = HistoryGrouping.sections(for: entries, now: now, calendar: calendar)
        #expect(sections.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(sections.first?.entries.count == 2 && sections.count == 3)
    }
}

@Suite struct InterpreterTrustTests {
    let me: uid_t = 501

    func lookup(_ table: [String: InterpreterTrust.Owner]) -> (String) -> InterpreterTrust.Owner? {
        { table[$0] }
    }

    @Test func trustsRootAndOwnPaths() {
        let table: [String: InterpreterTrust.Owner] = [
            "/": .init(uid: 0, mode: 0o755), "/opt": .init(uid: 0, mode: 0o755),
            "/opt/py": .init(uid: 501, mode: 0o775), "/opt/py/python3": .init(uid: 501, mode: 0o755),
        ]
        #expect(InterpreterTrust.isTrusted(path: "/opt/py/python3", currentUID: me, lookup: lookup(table)))
    }

    @Test func rejectsForeignOwnerOrWorldWritable() {
        var table: [String: InterpreterTrust.Owner] = [
            "/": .init(uid: 0, mode: 0o755), "/opt": .init(uid: 0, mode: 0o755),
            "/opt/python3": .init(uid: 502, mode: 0o755),
        ]
        #expect(!InterpreterTrust.isTrusted(path: "/opt/python3", currentUID: me, lookup: lookup(table)))
        table["/opt/python3"] = .init(uid: 501, mode: 0o755)
        table["/opt"] = .init(uid: 0, mode: 0o1777)
        #expect(!InterpreterTrust.isTrusted(path: "/opt/python3", currentUID: me, lookup: lookup(table)))
        #expect(!InterpreterTrust.isTrusted(path: "/missing", currentUID: me, lookup: lookup(table)))
    }

    @Test func realSystemPython() {
        #expect(InterpreterTrust.isTrusted(path: "/usr/bin/python3"))
    }
}

@Suite struct EditorRulesTests {
    @Test(arguments: [
        ("", 0, true), ("x = ", 4, true), ("(", 1, true), ("a = ()", 5, true),
        ("my", 2, false), ("np.", 3, false), ("x = 'a ", 7, false), ("# note ", 7, false),
        ("s = 'done'", 10, true), ("ab", 0, false), ("x = 1", 99, false),
    ])
    func printExpansion(source: String, cursor: Int, expected: Bool) {
        #expect(EditorRules.shouldExpandPrint(in: source, at: cursor) == expected)
    }

    @Test func indentation() {
        #expect(EditorRules.indentation(after: "    x = 1") == "    ")
        #expect(EditorRules.indentation(after: "def f(x):  # doc") == "    ")
        #expect(EditorRules.indentation(after: "") == "")
    }

    @Test func completionsMixScriptAndKnownNames() {
        let names = EditorRules.completions(for: "ra", in: "radius = 2\nrate2 = 3\nra", extra: ["rafters"])
        #expect(names.prefix(3).contains("range"))
        #expect(names.contains("radius") && names.contains("rate2") && names.contains("radians") && names.contains("rafters"))
        #expect(!names.contains("ra"))
        #expect(EditorRules.completions(for: "", in: "x").isEmpty)
        #expect(EditorRules.completions(for: "SQ", in: "") == ["sqrt"])
    }

    @Test func commentToggleRoundTrips() {
        let lines = ["    a = 1", "", "    b = 2"]
        let commented = EditorRules.toggleComment(lines)
        #expect(commented == ["    # a = 1", "", "    # b = 2"])
        #expect(EditorRules.toggleComment(commented) == lines)
    }
}
