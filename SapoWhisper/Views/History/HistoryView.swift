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

/// Main history window — custom HStack sidebar layout
struct HistoryView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @State private var entries: [HistoryEntry] = []
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @State private var engineFilter: EngineFilter = .all
    @State private var sidebarVisible = true
    @State private var showInspector = false
    @State private var showDeleteConfirmation = false
    @State private var searchTask: Task<Void, Never>?
    @State private var retranscribeEntry: HistoryEntry?
    @State private var selectedRetranscribeEngine: TranscriptionEngine = .appleOnline
    @State private var isRetranscribing = false
    @State private var showErrorAlert = false
    @State private var actionErrorMessage = ""

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            if sidebarVisible {
                HistorySidebarView(
                    entries: entries,
                    selection: $selectedEntry,
                    searchText: $searchText,
                    engineFilter: $engineFilter,
                    onTogglePin: handleTogglePin,
                    onDelete: handleDelete
                )
                .frame(width: 240)
                .background(SidebarMaterial())
                .transition(.move(edge: .leading))
            }

            Divider()

            // MARK: - Detail
            Group {
                if let entry = selectedEntry {
                    HistoryDetailView(entry: entry)
                        .inspector(isPresented: $showInspector) {
                            HistoryInspectorView(
                                entry: entry,
                                onCopy: { PasteManager.copyToClipboard(entry.text) },
                                onRetranscribe: { handleRetranscribe(entry) },
                                onDownloadAudio: { handleDownloadAudio(entry) },
                                onTogglePin: { handleTogglePin(entry) },
                                onDelete: { showDeleteConfirmation = true }
                            )
                            .inspectorColumnWidth(min: 200, ideal: 220, max: 260)
                        }
                } else {
                    HistoryEmptyDetailView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: sidebarVisible)
        .frame(minWidth: 800, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
            }

        }
        .onChange(of: selectedEntry) { _, newValue in
            showInspector = newValue != nil
        }
        .onChange(of: searchText) { _, _ in
            scheduleLoadEntries()
        }
        .onChange(of: engineFilter) { _, _ in
            loadEntries()
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptionHistoryManager.didChangeNotification)) { _ in
            loadEntries()
        }
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
        .onAppear(perform: loadEntries)
        .onDisappear {
            searchTask?.cancel()
        }
    }

    // MARK: - Data

    private func loadEntries() {
        let previousSelectionID = selectedEntry?.id
        entries = TranscriptionHistoryManager.shared.fetchEntries(
            searchText: searchText,
            engineFilter: engineFilter
        )
        selectedEntry = entries.first { $0.id == previousSelectionID } ?? entries.first
    }

    private func scheduleLoadEntries() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                loadEntries()
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
        .frame(width: 900, height: 560)
}
