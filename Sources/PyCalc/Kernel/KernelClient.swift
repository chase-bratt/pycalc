import Foundation
import PyCalcCore

enum KernelClientError: LocalizedError {
    case pythonNotFound
    case untrustedInterpreter(String)
    case outputTooLarge
    case kernelScriptMissing
    case terminated(String)
    case kernel(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound:
            return "No Python 3 interpreter found. Install Python (e.g. `brew install python`) and relaunch."
        case .untrustedInterpreter(let path):
            return "Refusing to run \(path): it, or a folder above it, can be modified by other users."
        case .outputTooLarge:
            return "The script produced more output than PyCalc can display. The Python process was restarted."
        case .kernelScriptMissing:
            return "PyCalc's kernel script is missing from the app bundle."
        case .terminated(let detail):
            return detail.isEmpty ? "The Python process stopped." : "The Python process stopped: \(detail)"
        case .kernel(let message):
            return message
        }
    }
}

/// Finds a Python 3 interpreter, preferring Homebrew over the system stub.
enum PythonLocator {
    static let overrideKey = "pythonPath"

    static func find(fileManager: FileManager = .default, defaults: UserDefaults = .standard) -> URL? {
        let candidates = [defaults.string(forKey: overrideKey)].compactMap { $0 } + [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/bin/python3",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    /// Variables passed to the kernel. Built from an allowlist so PYTHONPATH,
    /// PYTHONSTARTUP, DYLD_* and similar can't inject code into it.
    static func environment(from parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = parent.filter { ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR"].contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONIOENCODING"] = "utf-8"
        return environment
    }

    static func kernelScript() -> URL? {
        if let bundled = Bundle.main.url(forResource: "kernel", withExtension: "py") { return bundled }
        #if DEBUG
        // Running from `swift run`: use the source tree copy.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/kernel.py")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
        #else
        return nil
        #endif
    }
}

/// Owns the long-lived `kernel.py` process and matches replies to requests.
/// All mutable state is confined to `queue`. The kernel answers strictly in order,
/// and every request is guaranteed to be resumed exactly once.
final class KernelClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.pycalc.kernel")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var stderrTail = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private let decoder = JSONDecoder()

    /// Called on an arbitrary queue when the kernel announces itself.
    var onReady: (@Sendable (KernelHello) -> Void)?

    func run(code: String, degrees: Bool = false) async throws -> RunResult {
        let data = try await request { id in try KernelProtocol.encodeRun(id: id, code: code, degrees: degrees) }
        return try decoder.decode(RunResult.self, from: data)
    }

    func sample(xmin: Double, xmax: Double, n: Int, ids: [String]) async throws -> SampleSet {
        let data = try await request { id in
            try KernelProtocol.encodeSample(id: id, xmin: xmin, xmax: xmax, n: n, ids: ids)
        }
        return try decoder.decode(SampleSet.self, from: data)
    }

    /// Starts the interpreter ahead of the first run so ⌘↩ feels instant.
    func warmUp() {
        queue.async { try? self.ensureRunning() }
    }

    /// Raises KeyboardInterrupt in the running script; restarts the kernel if
    /// the requests outstanding at the time of the interrupt are still unanswered.
    func interrupt() {
        queue.async {
            guard let process = self.process, process.isRunning else { return }
            let targets = Set(self.pending.keys)
            process.interrupt()
            self.queue.asyncAfter(deadline: .now() + 1.5) {
                guard self.process === process, !targets.isDisjoint(with: self.pending.keys) else { return }
                process.terminate()
            }
        }
    }

    func shutdown() {
        queue.sync {
            guard let process else { return }
            process.terminate()
            handleTermination(of: process)
        }
    }

    // MARK: - Plumbing

    private func request(_ encode: @escaping (Int) throws -> Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.ensureRunning()
                    let id = self.nextID
                    self.nextID += 1
                    try self.input?.write(contentsOf: try encode(id))
                    self.pending[id] = continuation
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func ensureRunning() throws {
        if let process {
            if process.isRunning { return }
            // Died, but its termination callback hasn't run yet: settle its requests first.
            handleTermination(of: process)
        }
        guard let python = PythonLocator.find() else { throw KernelClientError.pythonNotFound }
        guard let script = PythonLocator.kernelScript() else { throw KernelClientError.kernelScriptMissing }

        let process = Process()
        process.executableURL = python
        guard InterpreterTrust.isTrusted(path: python.path) else {
            throw KernelClientError.untrustedInterpreter(python.path)
        }
        // -I: isolated mode — ignore PYTHON* variables and user site-packages.
        process.arguments = ["-I", "-u", script.path]
        process.environment = PythonLocator.environment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Chunks are tagged with their process so output from a dead kernel never
        // leaks into the next one's stream.
        stdout.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async {
                guard let self, let process, process === self.process else { return }
                self.consume(data)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.queue.async { self?.keepStderr(data) }
        }
        process.terminationHandler = { [weak self] finished in
            self?.queue.async { self?.handleTermination(of: finished) }
        }

        try process.run()
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.buffer = Data()
        self.stderrTail = Data()
    }

    /// Largest single reply accepted from the kernel before it is treated as runaway output.
    private static let maxReplyBytes = 64 * 1024 * 1024

    private func consume(_ data: Data) {
        buffer.append(data)
        if buffer.count > Self.maxReplyBytes, buffer.firstIndex(of: 0x0A) == nil, let process {
            let waiting = pending
            pending.removeAll()
            waiting.values.forEach { $0.resume(throwing: KernelClientError.outputTooLarge) }
            process.terminate()
            handleTermination(of: process)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            dispatch(Data(line))
        }
    }

    private func dispatch(_ line: Data) {
        guard let envelope = try? decoder.decode(KernelEnvelope.self, from: line) else { return }
        if envelope.op == "ready" {
            if let hello = try? decoder.decode(KernelHello.self, from: line) { onReady?(hello) }
            return
        }
        // Replies arrive in request order, so an error without an id belongs to the oldest request.
        guard let id = envelope.id ?? pending.keys.min(), let continuation = pending.removeValue(forKey: id) else { return }
        if envelope.op == "error" {
            let message = (try? decoder.decode(KernelFailure.self, from: line).message) ?? "Kernel error"
            continuation.resume(throwing: KernelClientError.kernel(message))
        } else {
            continuation.resume(returning: line)
        }
    }

    private func keepStderr(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > 4096 { stderrTail = stderrTail.suffix(4096) }
    }

    private func handleTermination(of finished: Process) {
        guard finished === process else { return }
        process = nil
        input = nil
        buffer = Data()
        let lastLine = String(decoding: stderrTail, as: UTF8.self)
            .split(separator: "\n").last.map(String.init) ?? ""
        let failure = KernelClientError.terminated(finished.isRunning || finished.terminationReason == .uncaughtSignal ? "" : lastLine)
        let waiting = pending
        pending.removeAll()
        waiting.values.forEach { $0.resume(throwing: failure) }
    }
}
