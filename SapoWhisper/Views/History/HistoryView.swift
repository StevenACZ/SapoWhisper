//
//  HistoryView.swift
//  SapoWhisper
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Native Sidebar Background

/// Wraps NSVisualEffectView with `.sidebar` material for native macOS sidebar look
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Main history window: sidebar list + wide reading pane. Metadata and
/// actions live inside the detail pane, so the transcript always gets the
/// full remaining width.
struct HistoryView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @State private var entries: [HistoryEntry] = []
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @State private var engineFilter: EngineFilter = .all
    @State private var sidebarVisible = true
    @State private var showDeleteConfirmation = false
    @State private var searchTask: Task<Void, Never>?
    @State private var retranscribeEntry: HistoryEntry?
    @State private var selectedRetranscribeEngine: TranscriptionEngine = .mlxWhisper
    @State private var isRetranscribing = false
    @State private var activeRetranscribeID: Int64?
    @State private var retranscribeTask: Task<Void, Never>?
    @State private var aiPolishTasks: [Int64: Task<Void, Never>] = [:]
    @State private var showErrorAlert = false
    @State private var actionErrorMessage = ""
    @State private var showNoticeAlert = false
    @State private var actionNoticeMessage = ""
    @State private var loadedPageCount = 1
    @State private var hasMorePages = false
    @State private var showClearAllConfirmation = false
    @State private var showDeleteOldConfirmation = false

    /// H3: rows fetched per page; scrolling near the end loads another page.
    private static let pageSize = 200
    private static let deleteOldThresholdDays = 30

    var body: some View {
        layout
            .confirmationDialog(
                "history.delete_confirm".localized,
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("history.delete".localized, role: .destructive) {
                    if let entry = selectedEntry {
                        handleDelete(entry)
                    }
                }
            } message: {
                Text("history.delete_confirm_message".localized)
            }
            .confirmationDialog(
                "history.delete_old".localized,
                isPresented: $showDeleteOldConfirmation,
                titleVisibility: .visible
            ) {
                Button("history.delete".localized, role: .destructive) {
                    cancelAllPolishTasks()
                    TranscriptionHistoryManager.shared.deleteEntries(olderThanDays: Self.deleteOldThresholdDays)
                    selectedEntry = nil
                    loadEntries()
                }
            } message: {
                Text("history.delete_old_confirm_message".localized)
            }
            .confirmationDialog(
                "history.clear_all".localized,
                isPresented: $showClearAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("history.delete".localized, role: .destructive) {
                    cancelAllPolishTasks()
                    TranscriptionHistoryManager.shared.deleteAll()
                    selectedEntry = nil
                    loadEntries()
                }
            } message: {
                Text("history.clear_all_confirm_message".localized)
            }
            .sheet(item: $retranscribeEntry) { entry in
                HistoryRetranscribeSheet(
                    entry: entry,
                    currentEngine: viewModel.currentEngine,
                    selectedEngine: $selectedRetranscribeEngine,
                    isProcessing: isRetranscribing,
                    isEngineReady: viewModel.isEngineReady
                ) {
                    performRetranscription(for: entry)
                } onCancel: {
                    if isRetranscribing {
                        retranscribeTask?.cancel()
                    } else {
                        retranscribeEntry = nil
                    }
                }
            }
            .alert("history.action_failed".localized, isPresented: $showErrorAlert) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(actionErrorMessage)
            }
            .alert("history.ai_polish_notice_title".localized, isPresented: $showNoticeAlert) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(actionNoticeMessage)
            }
            .onAppear {
                loadEntries()
                consumePendingFocusRequest()
            }
            .onDisappear {
                searchTask?.cancel()
                retranscribeTask?.cancel()
                cancelAllPolishTasks()
            }
            // Window already open when the overlay pill asks for an entry.
            .onReceive(NotificationCenter.default.publisher(for: HistoryFocusRequest.notification)) { _ in
                loadEntries()
                consumePendingFocusRequest()
            }
            // Reopen of the cached window: select the newest entry, never a
            // selection retained from the previous time it was open.
            .onReceive(
                NotificationCenter.default.publisher(
                    for: HistoryFocusRequest.windowPresentedNotification)
            ) { _ in
                selectedEntry = nil
                loadEntries(resetPaging: true)
                consumePendingFocusRequest()
            }
    }

    /// Selects the entry the overlay pill asked for (set before this window
    /// was opened or brought forward).
    private func consumePendingFocusRequest() {
        guard let entryId = HistoryFocusRequest.pendingEntryID else { return }
        HistoryFocusRequest.pendingEntryID = nil
        if let match = entries.first(where: { $0.id == entryId }) {
            selectedEntry = match
        }
    }

    private var layout: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            if sidebarVisible {
                HistorySidebarView(
                    entries: entries,
                    selection: $selectedEntry,
                    searchText: $searchText,
                    engineFilter: $engineFilter,
                    onTogglePin: handleTogglePin,
                    onDelete: handleDelete,
                    onRowAppear: loadMoreIfNeeded
                )
                .frame(width: 290)
                .background(SidebarMaterial())
                .transition(.move(edge: .leading))
            }

            Divider()

            // MARK: - Detail
            Group {
                if let entry = selectedEntry {
                    HistoryDetailView(
                        entry: entry,
                        isAIPolishing: aiPolishTasks[entry.id] != nil,
                        isRetryingTranscription: activeRetranscribeID == entry.id,
                        onCancelTranscription: { retranscribeTask?.cancel() },
                        onCancelPolish: { aiPolishTasks[entry.id]?.cancel() },
                        onCopy: { PasteManager.copyToClipboard(entry.text) },
                        onPolishWithAI: { option in handlePolishWithAI(entry, option: option) },
                        onRetranscribe: { handleRetranscribe(entry) },
                        canRetryTranscription: !isRetranscribing && !entry.isProcessing,
                        onRetryTranscription: {
                            guard !isRetranscribing, retranscribeTask == nil else { return }
                            selectedRetranscribeEngine = viewModel.currentEngine
                            performRetranscription(for: entry)
                        },
                        onDownloadAudio: { handleDownloadAudio(entry) },
                        onTogglePin: { handleTogglePin(entry) },
                        onExtendRetention: { handleExtendRetention(entry) },
                        canContinueRecording: activeRetranscribeID != entry.id && viewModel.canContinueHistoryEntry(entry),
                        onContinueRecording: {
                            guard activeRetranscribeID != entry.id, viewModel.canContinueHistoryEntry(entry) else { return }
                            if let audioPath = entry.audioPath { HistoryAudioPlayerController.shared.stopIfLoaded(path: audioPath) }
                            viewModel.continueHistoryEntry(entry)
                        },
                        onDelete: { showDeleteConfirmation = true }
                    )
                } else {
                    HistoryEmptyDetailView(hasEntries: !entries.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(Constants.Animation.transition, value: sidebarVisible)
        .frame(minWidth: 840, minHeight: 520)
        .navigationTitle("history.title".localized)
        .toolbar { historyToolbar }
        .onChange(of: searchText) { _, _ in
            scheduleLoadEntries()
        }
        .onChange(of: engineFilter) { _, _ in
            loadEntries(resetPaging: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionHistoryManager.didChangeNotification)) { _ in
            loadEntries()
        }
    }

    @ToolbarContentBuilder
    private var historyToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("history.toggle_sidebar".localized)
            .accessibilityLabel("history.toggle_sidebar".localized)
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Section("history.export".localized) {
                    ForEach(HistoryExportFormat.allCases) { format in
                        Button("history.export_as".localized(format.displayName)) {
                            handleExport(format)
                        }
                    }
                }

                Divider()

                Button(role: .destructive) {
                    showDeleteOldConfirmation = true
                } label: {
                    Label("history.delete_old".localized, systemImage: "calendar.badge.minus")
                }

                Button(role: .destructive) {
                    showClearAllConfirmation = true
                } label: {
                    Label("history.clear_all".localized, systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .help("history.more_actions".localized)
            .accessibilityLabel("history.more_actions".localized)
        }
    }

    // MARK: - Data

    /// Reloads the visible window. Search/filter changes reset to one page;
    /// refreshes after edits keep however many pages were already loaded.
    private func loadEntries(resetPaging: Bool = false) {
        if resetPaging {
            loadedPageCount = 1
        }
        let limit = Self.pageSize * loadedPageCount
        let previousSelectionID = selectedEntry?.id
        entries = TranscriptionHistoryManager.shared.fetchEntries(
            searchText: searchText,
            engineFilter: engineFilter,
            limit: limit
        )
        hasMorePages = entries.count == limit
        selectedEntry = entries.first { $0.id == previousSelectionID } ?? entries.first
    }

    /// H3: grows the window by one page when the last loaded row appears.
    private func loadMoreIfNeeded(_ entry: HistoryEntry) {
        guard hasMorePages, entry.id == entries.last?.id else { return }
        // Incremental paging: fetch only the next page by offset and append it,
        // instead of re-fetching every page loaded so far (which made a long
        // scroll O(pages^2) in rows read). fetchEntries already supports offset
        // on both the FTS and LIKE paths. Appending leaves the selection intact.
        let nextPage = TranscriptionHistoryManager.shared.fetchEntries(
            searchText: searchText,
            engineFilter: engineFilter,
            limit: Self.pageSize,
            offset: entries.count
        )
        loadedPageCount += 1
        entries.append(contentsOf: nextPage)
        hasMorePages = nextPage.count == Self.pageSize
    }

    private func scheduleLoadEntries() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadEntries(resetPaging: true)
            }
        }
    }

    // MARK: - Actions

    private func handleTogglePin(_ entry: HistoryEntry) {
        TranscriptionHistoryManager.shared.toggleFavorite(id: entry.id)
        loadEntries()
        selectedEntry = entries.first { $0.id == entry.id }
    }

    private func handleExtendRetention(_ entry: HistoryEntry) {
        guard TranscriptionHistoryManager.shared.extendRetention(id: entry.id) else { return }
        loadEntries()
        selectedEntry = entries.first { $0.id == entry.id }
    }

    private func handleDelete(_ entry: HistoryEntry) {
        guard entry.isDeletable else { return }
        aiPolishTasks[entry.id]?.cancel()
        TranscriptionHistoryManager.shared.delete(id: entry.id)
        selectedEntry = nil
        loadEntries()
    }

    private func handleRetranscribe(_ entry: HistoryEntry) {
        guard !isRetranscribing, retranscribeTask == nil, !entry.isProcessing else { return }
        selectedRetranscribeEngine = viewModel.currentEngine
        retranscribeEntry = entry
    }

    private func performRetranscription(for entry: HistoryEntry) {
        guard !isRetranscribing, retranscribeTask == nil, !entry.isProcessing else { return }
        isRetranscribing = true
        activeRetranscribeID = entry.id
        let engine = selectedRetranscribeEngine

        retranscribeTask = Task {
            let result = await viewModel.retranscribeHistoryEntry(entry, using: engine)

            await MainActor.run {
                isRetranscribing = false
                activeRetranscribeID = nil
                retranscribeEntry = nil
                retranscribeTask = nil

                if engineFilter != .all && !engineFilter.matches(engine.displayName) {
                    engineFilter = .all
                }

                loadEntries()
                selectedEntry = entries.first { $0.id == result.entryId }

                if let errorMessage = result.errorMessage {
                    presentActionError(errorMessage)
                }
            }
        }
    }

    private func handlePolishWithAI(_ entry: HistoryEntry, option: PolishModelOption?) {
        guard aiPolishTasks[entry.id] == nil else { return }
        aiPolishTasks[entry.id] = Task { @MainActor in
            defer { aiPolishTasks.removeValue(forKey: entry.id) }
            let result = await viewModel.polishHistoryEntry(entry, with: option)
            guard !Task.isCancelled else { return }
            loadEntries()
            if let errorMessage = result.errorMessage {
                presentActionError(errorMessage)
            } else if let noticeMessage = result.noticeMessage {
                presentActionNotice(noticeMessage)
            }
        }
    }

    private func cancelAllPolishTasks() {
        for task in aiPolishTasks.values { task.cancel() }
    }

    private func handleDownloadAudio(_ entry: HistoryEntry) {
        guard let audioPath = entry.audioPath, entry.audioFileExists else {
            presentActionError("history.audio_missing_error".localized)
            return
        }

        let sourceURL = URL(fileURLWithPath: audioPath)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "history.export_sensitive_notice".localized
        panel.nameFieldStringValue = exportFileName(for: entry, pathExtension: sourceURL.pathExtension)

        if let type = UTType(filenameExtension: sourceURL.pathExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            presentActionError(error.localizedDescription)
        }
    }

    /// H4: exports the currently filtered set (not just the loaded pages).
    private func handleExport(_ format: HistoryExportFormat) {
        let allFiltered = TranscriptionHistoryManager.shared.fetchEntries(
            searchText: searchText,
            engineFilter: engineFilter,
            limit: nil
        )
        guard !allFiltered.isEmpty else {
            presentActionError("history.export_empty".localized)
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "history.export_sensitive_notice".localized
        panel.nameFieldStringValue = HistoryExporter.suggestedFileName(for: format)
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        do {
            let rendered = HistoryExporter.render(allFiltered, as: format)
            try rendered.write(to: destinationURL, atomically: true, encoding: .utf8)
        } catch {
            presentActionError(error.localizedDescription)
        }
    }

    private func exportFileName(for entry: HistoryEntry, pathExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"

        let engineName = entry.displayEngineName
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")

        let sanitizedExtension = pathExtension.isEmpty ? "wav" : pathExtension
        return "sapowhisper-\(engineName)-\(formatter.string(from: entry.timestamp)).\(sanitizedExtension)"
    }

    private func presentActionError(_ message: String) {
        actionErrorMessage = message
        showErrorAlert = true
    }

    private func presentActionNotice(_ message: String) {
        actionNoticeMessage = message
        showNoticeAlert = true
    }
}

// MARK: - Previews

#Preview("History Window") {
    HistoryView(viewModel: SapoWhisperViewModel())
        .frame(width: 980, height: 620)
}
