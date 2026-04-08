//
//  HistorySidebarView.swift
//  SapoWhisper
//

import SwiftUI

/// Sidebar list with date-grouped sections and search
struct HistorySidebarView: View {
    let entries: [HistoryEntry]
    @Binding var selection: HistoryEntry?
    @Binding var searchText: String
    @Binding var engineFilter: EngineFilter
    let onTogglePin: (HistoryEntry) -> Void
    let onDelete: (HistoryEntry) -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(groupedEntries, id: \.group) { section in
                Section(section.group.localizedTitle) {
                    ForEach(section.entries) { entry in
                        HistoryRowView(entry: entry)
                            .tag(entry)
                            .contextMenu {
                                contextMenuItems(for: entry)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.tertiary)
                    TextField("history.search".localized, text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Picker("Filter", selection: $engineFilter) {
                    ForEach(EngineFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    // MARK: - Date Grouping

    private var groupedEntries: [(group: DateGroup, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let now = Date()

        var groups: [DateGroup: [HistoryEntry]] = [:]

        for entry in entries {
            if entry.isFavorite {
                groups[.pinned, default: []].append(entry)
            }

            let dateGroup: DateGroup
            if calendar.isDateInToday(entry.timestamp) {
                dateGroup = .today
            } else if calendar.isDateInYesterday(entry.timestamp) {
                dateGroup = .yesterday
            } else if calendar.isDate(entry.timestamp, equalTo: now, toGranularity: .weekOfYear) {
                dateGroup = .thisWeek
            } else if calendar.isDate(entry.timestamp, equalTo: now, toGranularity: .month) {
                dateGroup = .thisMonth
            } else {
                dateGroup = .older
            }
            groups[dateGroup, default: []].append(entry)
        }

        // Sort entries within each group by timestamp descending
        for key in groups.keys {
            groups[key]?.sort { $0.timestamp > $1.timestamp }
        }

        // Return in display order, skip empty groups
        return DateGroup.allCases.compactMap { group in
            guard let entries = groups[group], !entries.isEmpty else { return nil }
            return (group: group, entries: entries)
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenuItems(for entry: HistoryEntry) -> some View {
        Button {
            PasteManager.copyToClipboard(entry.text)
        } label: {
            Label("history.copy".localized, systemImage: "doc.on.doc")
        }

        Button {
            onTogglePin(entry)
        } label: {
            Label(
                entry.isFavorite ? "history.unpin".localized : "history.pin".localized,
                systemImage: entry.isFavorite ? "pin.slash" : "pin"
            )
        }

        Divider()

        Button(role: .destructive) {
            onDelete(entry)
        } label: {
            Label("history.delete".localized, systemImage: "trash")
        }
    }
}

// MARK: - Preview

#Preview("Sidebar") {
    HistorySidebarView(
        entries: HistoryEntry.mockData,
        selection: .constant(HistoryEntry.mockData.first),
        searchText: .constant(""),
        engineFilter: .constant(.all),
        onTogglePin: { _ in },
        onDelete: { _ in }
    )
    .frame(width: 260, height: 500)
}
