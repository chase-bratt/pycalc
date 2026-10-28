import AppKit
import SwiftUI

@main
struct PyCalcApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Python Calculator", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    appDelegate.model = model
                    #if DEBUG
                    DebugSnapshot.runIfRequested(model: model)
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands { PyCalcCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // A dead kernel must surface as a write error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        UserDefaults.standard.register(defaults: [CodeTextView.printShortcutKey: true])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.shutdown() }
    }
}

struct PyCalcCommands: Commands {
    @ObservedObject var model: AppModel
    @AppStorage(CodeTextView.printShortcutKey) private var shiftPInsertsPrint = true

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Scratch") { model.newScratch() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandMenu("Script") {
            Button("Run") { model.run() }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Stop") { model.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Toggle("Live Mode", isOn: $model.liveMode)
                .keyboardShortcut("l", modifiers: [.command, .option])
            Toggle("Use Degrees", isOn: $model.usesDegrees)
                .keyboardShortcut("d", modifiers: [.command, .option])
            Divider()
            Button("Copy Result") { model.copyResult() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.result?.value == nil)
            Divider()
            // ⇧P itself is handled by the editor so a capital P still types normally inside names.
            Button("Insert print()") { model.insertPrint() }
            Toggle("⇧P Inserts print()", isOn: $shiftPInsertsPrint)
            Button("Insert plot()") { model.insertPlot() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Toggle Comment") { model.toggleComment() }
                .keyboardShortcut("/", modifiers: .command)
            Divider()
            Button("Clear Output") { model.clearOutput() }
                .keyboardShortcut("k", modifiers: .command)
        }
        CommandGroup(replacing: .help) {
            Button("Quick Reference") { model.toggleReference() }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Show History") { model.toggleHistory() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Toggle("Float on Top", isOn: $model.floatsOnTop)
                .keyboardShortcut("t", modifiers: [.command, .option])
            Divider()
            Button("Zoom Graph In") { model.graph.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Graph Out") { model.graph.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Reset Graph") { model.graph.home() }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
