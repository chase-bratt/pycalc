import SwiftUI

/// Cheat sheet of plot helpers, math names and shortcuts. Clicking an entry inserts it.
struct ReferencePopover: View {
    @EnvironmentObject private var model: AppModel

    /// `|` marks where the caret lands after inserting.
    private struct Entry: Identifiable {
        let snippet: String
        let note: String
        var label: String?
        var id: String { snippet }
        var display: String { label ?? snippet.replacingOccurrences(of: "|", with: "") }
    }

    private let plotting: [Entry] = [
        .init(snippet: "plot(|)", note: "functions, \"x**2\" strings or numbers", label: "plot(f)"),
        .init(snippet: "scatter([|], [])", note: "points from xs, ys", label: "scatter(xs, ys)"),
        .init(snippet: "line([|], [])", note: "connected points", label: "line(xs, ys)"),
        .init(snippet: "point(|, , label=\"A\")", note: "one labelled point", label: "point(x, y, label=\"A\")"),
        .init(snippet: "parametric(cos, sin, t=(0, 2*pi))|", note: "curve (fx(t), fy(t))", label: "parametric(fx, fy, t=(a, b))"),
        .init(snippet: "polar(\"1 + cos(theta)\")|", note: "r(θ) curve"),
        .init(snippet: "vline(|)", note: "vertical line", label: "vline(x)"),
        .init(snippet: "window(-10, 10, -6, 6)|", note: "starting view"),
    ]

    private let math: [Entry] = [
        .init(snippet: "ans|", note: "previous result"),
        .init(snippet: "sqrt(|)", note: "square root", label: "sqrt(x)"),
        .init(snippet: "log(|)", note: "natural log; log(x, base)", label: "log(x)"),
        .init(snippet: "exp(|)", note: "e to the x", label: "exp(x)"),
        .init(snippet: "factorial(|)", note: "n!", label: "factorial(n)"),
        .init(snippet: "comb(|, )", note: "n choose k", label: "comb(n, k)"),
        .init(snippet: "radians(|)", note: "degrees → radians", label: "radians(deg)"),
        .init(snippet: "degrees(|)", note: "radians → degrees", label: "degrees(rad)"),
        .init(snippet: "hypot(|, )", note: "√(x² + y²)", label: "hypot(x, y)"),
        .init(snippet: "round(|, 2)", note: "round to places", label: "round(x, 2)"),
    ]

    private let shortcuts: [(String, String)] = [
        ("⌘↵", "Run"), ("⌘.", "Stop"), ("⌥⌘L", "Live mode"), ("⌥⌘D", "Degrees / radians"),
        ("⇧⌘C", "Copy result"), ("⇧P", "Insert print()"), ("Esc", "Complete name"), ("⌘/", "Comment"),
        ("⇧⌘H", "History"), ("⌥⌘T", "Float on top"), ("⌘= ⌘- ⌘0", "Graph zoom / reset"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("PLOTTING", plotting)
                section("MATH  ·  pi, e, tau, inf built in", math)
                VStack(alignment: .leading, spacing: 6) {
                    header("SHORTCUTS")
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        ForEach(shortcuts, id: \.0) { keys, label in
                            GridRow {
                                Keycap(keys: keys)
                                Text(label).font(.system(size: 12)).foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 360, height: 520)
        .background(Color(Theme.chrome))
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Color.textTertiary)
    }

    private func section(_ title: String, _ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            header(title)
            ForEach(entries) { entry in
                ReferenceRow(code: entry.display, note: entry.note) {
                    model.insertSnippet(entry.snippet)
                    model.showReference = false
                }
            }
        }
    }
}

private struct ReferenceRow: View {
    let code: String
    let note: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.mint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hovering ? Color.plum.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Insert \(code)")
    }
}
