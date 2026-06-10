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
    @State private var selectedRetranscribeEngine: TranscriptionEngine = .whisperLocal
    @State private var isRetranscribing = false
    @State private var aiPolishingEntryID: Int64?
    @State private var showErrorAlert = false
    @State private var actionErrorMessage = ""
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
                    if !isRetranscribing {
                        retranscribeEntry = nil
                    }
                }
            }
            .alert("history.action_failed".localized, isPresented: $showErrorAlert) {
                Button("common.ok".localized, role: .cancel) {}
            } message: {
                Text(actionErrorMessage)
            }
            .onAppear(perform: { loadEntries() })
            .onDisappear {
                searchTask?.cancel()
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
                        isAIPolishing: aiPolishingEntryID == entry.id,
                        onCopy: { PasteManager.copyToClipboard(entry.text) },
                        onPolishWithAI: { handlePolishWithAI(entry) },
                        onRetranscribe: { handleRetranscribe(entry) },
                        onDownloadAudio: { handleDownloadAudio(entry) },
                        onTogglePin: { handleTogglePin(entry) },
                        onDelete: { showDeleteConfirmation = true }
                    )
                } else {
                    HistoryEmptyDetailView(hasEntries: !entries.isEmpty)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: sidebarVisible)
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
        loadedPageCount += 1
        let previousSelectionID = selectedEntry?.id
        let limit = Self.pageSize * loadedPageCount
        entries = TranscriptionHistoryManager.shared.fetchEntries(
            searchText: searchText,
            engineFilter: engineFilter,
            limit: limit
        )
        hasMorePages = entries.count == limit
        selectedEntry = entries.first { $0.id == previousSelectionID }
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

    private func handleDelete(_ entry: HistoryEntry) {
        TranscriptionHistoryManager.shared.delete(id: entry.id)
        selectedEntry = nil
        loadEntries()
    }

    private func handleRetranscribe(_ entry: HistoryEntry) {
        selectedRetranscribeEngine = viewModel.currentEngine
        retranscribeEntry = entry
    }

    private func performRetranscription(for entry: HistoryEntry) {
        isRetranscribing = true

        Task {
            let result = await viewModel.retranscribeHistoryEntry(entry, using: selectedRetranscribeEngine)

            await MainActor.run {
                isRetranscribing = false
                retranscribeEntry = nil

                if engineFilter != .all && !engineFilter.matches(selectedRetranscribeEngine.displayName) {
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

    private func handlePolishWithAI(_ entry: HistoryEntry) {
        aiPolishingEntryID = entry.id

        Task {
            let result = await viewModel.polishHistoryEntry(entry)

            await MainActor.run {
                aiPolishingEntryID = nil
                loadEntries()
                selectedEntry = entries.first { $0.id == result.entryId }

                if let errorMessage = result.errorMessage {
                    presentActionError(errorMessage)
                }
            }
        }
    }

    private func handleDownloadAudio(_ entry: HistoryEntry) {
        guard let audioPath = entry.audioPath, entry.audioFileExists else {
            presentActionError("history.audio_missing_error".localized)
            return
        }

        let sourceURL = URL(fileURLWithPath: audioPath)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
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
}

// MARK: - Previews

#Preview("History Window") {
    HistoryView(viewModel: SapoWhisperViewModel())
        .frame(width: 980, height: 620)
}
