#if DEBUG
import AppKit

/// Debug builds only: renders README screenshots without Screen Recording permission.
///
///     PyCalc --snapshot out.png [--script file.py] [--seed dir] [--history] [--reference] [--degrees] [--live]
///
/// Loads the script, runs it, captures the window (and the reference popover when
/// asked) from inside the app, then quits. Not compiled into release builds.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(model: AppModel) {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let output = URL(fileURLWithPath: args[index + 1])
        if let scriptIndex = args.firstIndex(of: "--script"), scriptIndex + 1 < args.count,
           let code = try? String(contentsOfFile: args[scriptIndex + 1], encoding: .utf8) {
            model.editor.replaceAll(with: code)
        }
        if let seedIndex = args.firstIndex(of: "--seed"), seedIndex + 1 < args.count {
            let folder = URL(fileURLWithPath: args[seedIndex + 1])
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let scripts = files.filter { $0.pathExtension == "py" }.compactMap { url -> (String, String)? in
                guard let code = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return (code, url.deletingPathExtension().lastPathComponent)
            }
            model.seedHistory(scripts.map { (code: $0.0, summary: $0.1) })
        }
        model.usesDegrees = args.contains("--degrees")
        model.liveMode = args.contains("--live")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            model.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if args.contains("--history") { model.showHistory = true }
                if args.contains("--reference") { model.showReference = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    capture(to: output)
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private static func capture(to url: URL) {
        for window in NSApp.windows where window.isVisible {
            guard let frameView = window.contentView?.superview else { continue }
            let isMain = !String(describing: type(of: window)).contains("Popover") && window.frame.height > 300
            let target = isMain ? url : url.deletingPathExtension().appendingPathExtension("popover.png")
            guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: target)
        }
    }
}
#endif
