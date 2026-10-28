import PyCalcCore
import SwiftUI

/// Top-right pane: printed lines, then the script's final value in calculator-display size.
struct OutputPane: View {
    @EnvironmentObject private var model: AppModel

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "hh:mm:ss a"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "OUTPUT", detail: detail) {
                if let toast = model.toast {
                    Label(toast, systemImage: "checkmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.citrine)
                        .lineLimit(1)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else if model.result != nil || model.transportError != nil {
                    Button("Clear", action: model.clearOutput)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textSecondary)
                        .keyboardShortcut("k", modifiers: .command)
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(Theme.output))
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }

    private var detail: String {
        if model.isRunning { return "Running…" }
        guard let result = model.result, let date = model.lastRunAt else { return "" }
        return "Ran in \(formatDuration(result.durationMs)) · \(Self.timeFormat.string(from: date))"
    }

    private func formatDuration(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms.rounded())) ms" : String(format: "%.2f s", ms / 1000)
    }

    @ViewBuilder private var content: some View {
        if let message = model.transportError {
            ScrollView { ErrorBlock(title: "Python unavailable", message: message).padding(16) }
        } else if let result = model.result {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PrintedLines(text: result.stdout)
                    if let error = result.error {
                        ErrorBlock(title: "\(error.type)\(error.line.map { " · line \($0)" } ?? "")", message: error.traceback)
                            .padding(.top, result.stdout.isEmpty ? 0 : 14)
                    }
                    if let value = result.value {
                        if !result.stdout.isEmpty { Color.hairline.frame(height: 1).padding(.vertical, 14) }
                        ResultValue(value: value) { model.copyResult() }
                        if !result.alternates.isEmpty {
                            AlternateForms(forms: result.alternates) { model.copy($0.text, confirmation: "Copied \($0.label)") }
                                .padding(.top, 10)
                        }
                    }
                    if result.ok, result.stdout.isEmpty, result.value == nil {
                        Text(result.plots.isEmpty ? "Done — nothing printed." : "Plotted \(result.plots.count) item\(result.plots.count == 1 ? "" : "s").")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.textTertiary)
                    }
                    if !result.variables.isEmpty {
                        VariablesList(variables: result.variables,
                                      onInsert: { model.insert($0.name) },
                                      onCopy: { model.copy($0.value, confirmation: "Copied \($0.name)") })
                            .padding(.top, 18)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
        } else if model.isRunning {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyOutput()
        }
    }
}

private struct PrintedLines: View {
    let text: String
    private static let maxLines = 3000

    var body: some View {
        let lines = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).dropLast(text.hasSuffix("\n") ? 1 : 0)
        LazyVStack(alignment: .leading, spacing: 5) {
            ForEach(Array(lines.prefix(Self.maxLines).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("›").foregroundStyle(Color.textTertiary)
                    Text(String(line)).foregroundStyle(Color.textPrimary)
                }
                .font(.system(size: 13, design: .monospaced))
            }
            if lines.count > Self.maxLines {
                Text("… \(lines.count - Self.maxLines) more lines")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
            }
        }
    }
}

private struct ErrorBlock: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.coral)
            Text(message)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Color.textPrimary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.coral.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.coral.opacity(0.25)))
    }
}

private struct EmptyOutput: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("=")
                .font(.system(size: 34, weight: .light, design: .monospaced))
                .foregroundStyle(Color.citrine.opacity(0.35))
            HStack(spacing: 6) {
                Text("Press").foregroundStyle(Color.textTertiary)
                Keycap(keys: "⌘↵")
                Text("to run your script").foregroundStyle(Color.textTertiary)
            }
            .font(.system(size: 12))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
