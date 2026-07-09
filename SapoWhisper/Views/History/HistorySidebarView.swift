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
    /// H3: lets the owner grow the page window when the last row scrolls in.
    var onRowAppear: ((HistoryEntry) -> Void)?

    var body: some View {
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                List(selection: $selection) {
                    ForEach(groupedEntries, id: \.group) { section in
                        Section(section.group.localizedTitle) {
                            ForEach(section.entries) { entry in
                                HistoryRowView(entry: entry)
                                    .tag(entry)
                                    .contextMenu {
                                        contextMenuItems(for: entry)
                                    }
                                    .onAppear {
                                        onRowAppear?(entry)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                    TextField("history.search".localized, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("common.clear_search".localized)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                engineFilterMenu
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    /// Search/filter combinations that come back empty deserve a real answer,
    /// not a blank list.
    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: hasActiveFilter ? "magnifyingglass" : "clock.arrow.circlepath")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text((hasActiveFilter ? "history.no_results" : "history.empty").localized)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var hasActiveFilter: Bool {
        !searchText.isEmpty || engineFilter != .all
    }

    /// Engine filter as a compact menu next to the search field; the chip row
    /// never fit the sidebar width and clipped mid-label. The pill grows to
    /// name the active filter so a narrowed list is never a mystery.
    private var engineFilterMenu: some View {
        Menu {
            Picker("", selection: $engineFilter.animation(.easeInOut(duration: 0.18))) {
                ForEach(EngineFilter.allCases) { filter in
                    Label(filter.displayName, systemImage: filter.iconName)
                        .tag(filter)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: engineFilter.iconName)
                    .font(.system(size: 13, weight: .medium))

                if engineFilter != .all {
                    Text(engineFilter.displayName)
                        .font(.caption.weight(.semibold))
                }
            }
            .foregroundStyle(engineFilter == .all ? Color.secondary : activeFilterTint)
            .padding(.horizontal, engineFilter == .all ? 5 : 9)
            .padding(.vertical, 7)
            .background {
                if engineFilter != .all {
                    Capsule().fill(activeFilterTint.opacity(0.14))
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .animation(Constants.Animation.reveal, value: engineFilter)
        .help(engineFilter.displayName)
        .accessibilityLabel("history.filter_by_engine".localized)
        .accessibilityValue(engineFilter.displayName)
    }

    private var activeFilterTint: Color {
        switch engineFilter {
        case .all: return .secondary
        case .whisper: return .purple
        case .localAI: return .indigo
        case .deepgram: return .blue
        case .elevenLabs: return .teal
        case .other: return .gray
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
