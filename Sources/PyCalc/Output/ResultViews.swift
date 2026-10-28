import PyCalcCore
import SwiftUI

/// The calculator display: the script's final value, click (or ⇧⌘C) to copy.
struct ResultValue: View {
    let value: String
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        let compact = value.count > 28 || value.contains("\n")
        Button(action: onCopy) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("=")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.textTertiary)
                Text(value)
                    .font(.system(size: compact ? 16 : 30, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.citrine)
                    .shadow(color: Color.citrine.opacity(hovering ? 0.65 : 0.45), radius: hovering ? 18 : 14)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .opacity(hovering ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Copy result (⇧⌘C)")
        .accessibilityLabel("Result \(value). Copy")
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// Other renderings of the result (grouped, scientific, fraction, hex…). Click to copy.
struct AlternateForms: View {
    let forms: [AlternateForm]
    let onCopy: (AlternateForm) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(forms, id: \.self) { form in
                Chip(form: form) { onCopy(form) }
            }
        }
    }

    private struct Chip: View {
        let form: AlternateForm
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(form.label)
                        .foregroundStyle(Color.textTertiary)
                    Text(form.text)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(Color.white.opacity(hovering ? 0.09 : 0.05)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Copy \(form.label)")
        }
    }
}

/// Names the script defined, with their values. Click a name to insert it; click a value to copy.
struct VariablesList: View {
    let variables: [Variable]
    let onInsert: (Variable) -> Void
    let onCopy: (Variable) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("VARIABLES")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(Color.textTertiary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(variables, id: \.self) { variable in
                    GridRow {
                        Button(variable.name) { onInsert(variable) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.lavender)
                            .help("Insert \(variable.name) at the cursor")
                        Button(variable.value) { onCopy(variable) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("Copy value")
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.05)))
    }
}

/// Wraps children onto new lines when they run out of width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(subviews, width: bounds.width)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
