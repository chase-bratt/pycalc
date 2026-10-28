import AppKit
import PyCalcCore
import SwiftUI

/// Every script run in the last 30 days, grouped by day. Click to reopen.
struct HistorySidebar: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "HISTORY", detail: model.savesHistory ? "30 days" : "paused") {
                Menu {
                    Toggle("Save Runs to History", isOn: $model.savesHistory)
                    Divider()
                    Button("Clear All History…", role: .destructive) { confirmingClear = true }
                        .disabled(model.history.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("History options")
                IconButton(symbol: "xmark", help: "Hide History (⇧⌘H)", size: 22, action: model.toggleHistory)
            }
            .confirmationDialog("Delete all saved scripts?", isPresented: $confirmingClear) {
                Button("Delete All", role: .destructive, action: model.clearHistory)
            } message: {
                Text("This permanently removes every script in your history.")
            }
            searchField.padding(10)
            if let error = model.historyError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.coral)
                    .padding(.horizontal, 14)
            }
            if model.history.isEmpty {
                Text(model.historyQuery.isEmpty ? "Scripts you run are saved here for 30 days." : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                Spacer()
            } else {
                list
            }
        }
        .background(Color(Theme.chrome))
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textTertiary)
            TextField("Search scripts", text: $model.historyQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.white.opacity(0.06)))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(HistoryGrouping.sections(for: model.history)) { section in
                    Section {
                        ForEach(section.entries) { entry in HistoryRow(entry: entry) }
                    } header: {
                        Text(section.title.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1)
                            .foregroundStyle(Color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)
                            .background(Color(Theme.chrome))
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }
}

private struct HistoryRow: View {
    @EnvironmentObject private var model: AppModel
    let entry: HistoryEntry
    @State private var hovering = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Button { model.open(entry) } label: {
            HStack(alignment: .top, spacing: 9) {
                Circle()
                    .fill(entry.succeeded ? Color.mint : Color.coral)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        Text(Self.time.string(from: entry.createdAt))
                        if !entry.summary.isEmpty {
                            Text(entry.summary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovering ? Color.plum.opacity(0.45) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(entry.code)
        .contextMenu {
            Button("Open in Editor") { model.open(entry) }
            Button("Copy Script") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.code, forType: .string)
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(entry) }
        }
    }
}
