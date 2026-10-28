import AppKit
import Combine
import PyCalcCore

enum KernelState: Equatable {
    case starting
    case ready(version: String)
    case running
    case failed(String)
}

/// Cursor position and language info shown in the status bar.
@MainActor
final class EditorStatus: ObservableObject {
    @Published var line = 1
    @Published var column = 1
}

/// App-wide state: the script, the last run, plots and history.
@MainActor
final class AppModel: ObservableObject {
    static let draftKey = "draftScript"
    static let floatKey = "floatsOnTop"
    static let degreesKey = "angleDegrees"
    static let liveKey = "liveMode"
    static let saveHistoryKey = "saveHistory"
    /// Pause after typing before a live run, and the longest a live run may take.
    static let liveDelay: TimeInterval = 0.45
    static let liveBudget: TimeInterval = 2
    static let sampleScript = """
    # Damped wave vs. parabola
    # ⌘↵ runs · ⇧P inserts print()

    def f(x):
        return 4 * sin(x) * exp(-abs(x) / 6)

    g = lambda x: x**2 / 8 - 2

    area = sum(f(i / 1000) / 1000 for i in range(6283))
    print(f"f(π/2) = {f(pi / 2):.5f}")
    print(f"area of f on [0, 2π] ≈ {area:.4f}")

    plot(f)
    plot(g, label="g(x)")
    plot("cos(x) - 1")

    sqrt(2) * pi

    """

    @Published private(set) var result: RunResult?
    @Published private(set) var lastRunAt: Date?
    @Published private(set) var kernelState: KernelState = .starting
    @Published private(set) var transportError: String?
    @Published private(set) var plots: [PlotItem] = []
    @Published private(set) var plotWindow: [Double]?
    @Published private(set) var runGeneration = 0
    @Published var hiddenPlots: Set<String> = []
    @Published var showHistory = false
    @Published var floatsOnTop = UserDefaults.standard.bool(forKey: AppModel.floatKey) {
        didSet {
            UserDefaults.standard.set(floatsOnTop, forKey: Self.floatKey)
            applyWindowLevel()
        }
    }
    @Published var usesDegrees = UserDefaults.standard.bool(forKey: AppModel.degreesKey) {
        didSet {
            UserDefaults.standard.set(usesDegrees, forKey: Self.degreesKey)
            scheduleLiveRun()
        }
    }
    @Published var liveMode = UserDefaults.standard.bool(forKey: AppModel.liveKey) {
        didSet {
            UserDefaults.standard.set(liveMode, forKey: Self.liveKey)
            if liveMode { scheduleLiveRun() }
        }
    }
    @Published var showReference = false
    /// When off, runs are not written to the history database.
    @Published var savesHistory = UserDefaults.standard.object(forKey: AppModel.saveHistoryKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(savesHistory, forKey: Self.saveHistoryKey) }
    }
    @Published private(set) var pythonExecutable = ""
    /// Brief confirmation shown in the output header, e.g. "Copied".
    @Published private(set) var toast: String?
    @Published var historyQuery = "" { didSet { reloadHistory() } }
    @Published private(set) var history: [HistoryEntry] = []
    @Published private(set) var historyError: String?

    /// The main window, attached once SwiftUI creates it.
    weak var window: NSWindow? {
        didSet { applyWindowLevel() }
    }
    let editorStatus = EditorStatus()
    let editor = EditorController()
    let graph = GraphController()
    private let kernel = KernelClient()
    private let store: HistoryStore?
    private var pythonVersion = ""
    private var draftSave: DispatchWorkItem?
    private var liveRun: DispatchWorkItem?
    private var toastClear: DispatchWorkItem?

    var isRunning: Bool { kernelState == .running }
    var pythonLabel: String { pythonVersion.isEmpty ? "Python" : "Python \(pythonVersion)" }

    init() {
        do {
            store = try HistoryStore(path: Self.historyPath())
        } catch {
            store = nil
            historyError = error.localizedDescription
        }
        editor.text = UserDefaults.standard.string(forKey: Self.draftKey) ?? Self.sampleScript
        editor.onChange = { [weak self] text in
            self?.scheduleDraftSave(text)
            self?.scheduleLiveRun()
        }
        editor.completionNames = { [weak self] in self?.result?.variables.map(\.name) ?? [] }
        editor.onCopy = { [weak self] value in self?.copy(value, confirmation: "Copied \(value.prefix(24))") }
        editor.onCursor = { [weak self] line, column in
            self?.editorStatus.line = line
            self?.editorStatus.column = column
        }
        graph.sampler = { [weak self] xmin, xmax, n, ids in
            guard let self else { return nil }
            return try? await self.kernel.sample(xmin: xmin, xmax: xmax, n: n, ids: ids)
        }
        graph.onShowAll = { [weak self] in
            guard let self else { return }
            hiddenPlots = []
            graph.hidden = []
        }
        graph.onCopy = { [weak self] text in self?.copy(text, confirmation: "Copied \(text)") }
        graph.onToast = { [weak self] message in self?.showToast(message) }
        kernel.onReady = { [weak self] hello in
            Task { @MainActor in self?.kernelDidStart(hello) }
        }
        kernel.warmUp()
        reloadHistory()
    }

    private static func historyPath() throws -> String {
        #if DEBUG
        // Screenshot runs use a throwaway database so real history is never touched.
        if CommandLine.arguments.contains("--snapshot") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("pycalc-snapshot-\(ProcessInfo.processInfo.processIdentifier).sqlite").path
        }
        #endif
        return try HistoryStore.defaultURL().path
    }

    #if DEBUG
    func seedHistory(_ scripts: [(code: String, summary: String)]) {
        for script in scripts { try? store?.record(code: script.code, summary: script.summary, succeeded: true) }
        reloadHistory()
    }
    #endif

    func shutdown() {
        saveDraft(editor.text)
        kernel.shutdown()
    }

    // MARK: - Running

    /// Runs the script. Live runs (typing pauses in live mode) are time-boxed,
    /// don't scroll to errors and aren't saved to history.
    func run(live: Bool = false) {
        guard !isRunning else { return }
        liveRun?.cancel()
        let code = editor.text
        kernelState = .running
        transportError = nil
        editor.clearErrorLine()
        if live {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveBudget) { [weak self] in
                guard let self, self.isRunning, self.editor.text == code else { return }
                self.kernel.interrupt()
            }
        }
        Task {
            do {
                let result = try await kernel.run(code: code, degrees: usesDegrees)
                apply(result, code: code, live: live)
            } catch {
                transportError = error.localizedDescription
                kernelState = pythonVersion.isEmpty ? .failed(error.localizedDescription) : .ready(version: pythonVersion)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        kernel.interrupt()
    }

    func clearOutput() {
        result = nil
        transportError = nil
        lastRunAt = nil
        editor.showAnnotations([:])
    }

    private func apply(_ result: RunResult, code: String, live: Bool) {
        self.result = result
        lastRunAt = Date()
        kernelState = .ready(version: pythonVersion)
        // Plots hidden in the legend stay hidden while they still exist.
        hiddenPlots = hiddenPlots.intersection(result.plots.map(\.id))
        plots = result.plots
        plotWindow = result.window
        runGeneration += 1
        graph.load(plots: result.plots, window: result.window, generation: runGeneration)
        graph.hidden = hiddenPlots
        editor.showAnnotations(result.annotations)
        if let line = result.error?.line { editor.markErrorLine(line, scroll: !live) }
        if !live, savesHistory { record(code: code, result: result) }
        // The script changed while this run was in flight: catch up.
        if liveMode, editor.text != code { scheduleLiveRun() }
    }

    private func scheduleLiveRun() {
        guard liveMode else { return }
        liveRun?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.liveMode else { return }
            if self.isRunning { self.scheduleLiveRun() } else { self.run(live: true) }
        }
        liveRun = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveDelay, execute: work)
    }

    // MARK: - Results

    func copyResult() {
        guard let value = result?.value else { return }
        copy(value, confirmation: "Copied result")
    }

    func copy(_ text: String, confirmation: String = "Copied") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(confirmation)
    }

    func showToast(_ message: String) {
        toast = message
        toastClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    /// Inserts text (e.g. a variable name or reference snippet) at the caret.
    func insert(_ text: String) {
        editor.insertSnippet(prefix: text, suffix: "")
    }

    func insertSnippet(_ snippet: String) {
        if let caret = snippet.range(of: "|") {
            editor.insertSnippet(prefix: String(snippet[..<caret.lowerBound]), suffix: String(snippet[caret.upperBound...]))
        } else {
            insert(snippet)
        }
    }

    private func kernelDidStart(_ hello: KernelHello) {
        pythonVersion = hello.python
        pythonExecutable = hello.executable ?? ""
        if kernelState != .running { kernelState = .ready(version: hello.python) }
    }

    func togglePlot(_ id: String) {
        if hiddenPlots.contains(id) { hiddenPlots.remove(id) } else { hiddenPlots.insert(id) }
        graph.hidden = hiddenPlots
    }

    // MARK: - Editor commands

    func insertPrint() { editor.insertSnippet(prefix: "print(", suffix: ")") }
    func insertPlot() { editor.insertSnippet(prefix: "plot(", suffix: ")") }
    func toggleComment() { editor.toggleComment() }

    func newScratch() {
        editor.replaceAll(with: "")
        clearOutput()
    }

    func toggleDegrees() { usesDegrees.toggle() }
    func toggleLiveMode() { liveMode.toggle() }
    func toggleReference() { showReference.toggle() }

    // MARK: - Window

    func toggleFloatOnTop() { floatsOnTop.toggle() }

    /// Floating windows stay above other apps' windows and follow the user across Spaces.
    private func applyWindowLevel() {
        guard let window else { return }
        window.level = floatsOnTop ? .floating : .normal
        if floatsOnTop {
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.collectionBehavior.insert(.fullScreenAuxiliary)
        } else {
            window.collectionBehavior.remove(.canJoinAllSpaces)
            window.collectionBehavior.remove(.fullScreenAuxiliary)
        }
    }

    // MARK: - History

    func toggleHistory() {
        showHistory.toggle()
        if showHistory { reloadHistory() }
    }

    func open(_ entry: HistoryEntry) {
        editor.replaceAll(with: entry.code)
    }

    func delete(_ entry: HistoryEntry) {
        do {
            try store?.delete(id: entry.id)
            reloadHistory()
        } catch {
            historyError = error.localizedDescription
        }
    }

    func clearHistory() {
        do {
            try store?.deleteAll()
            reloadHistory()
            showToast("History cleared")
        } catch {
            historyError = error.localizedDescription
        }
    }

    func reloadHistory() {
        guard let store else { return }
        do {
            history = try store.entries(matching: historyQuery)
            historyError = nil
        } catch {
            historyError = error.localizedDescription
        }
    }

    private func record(code: String, result: RunResult) {
        let summary = result.error.map { "\($0.type): \($0.message)" }
            ?? result.value
            ?? result.stdout.split(separator: "\n").last.map(String.init)
            ?? ""
        do {
            try store?.record(code: code, summary: summary, succeeded: result.ok)
            reloadHistory()
        } catch {
            historyError = error.localizedDescription
        }
    }

    // MARK: - Draft persistence

    private func scheduleDraftSave(_ text: String) {
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveDraft(text) }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func saveDraft(_ text: String) {
        UserDefaults.standard.set(text, forKey: Self.draftKey)
    }
}
