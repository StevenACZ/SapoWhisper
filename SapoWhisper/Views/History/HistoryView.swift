//
//  HistoryView.swift
//  SapoWhisper
//

import AppKit
import SwiftUI

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
    @State private var entries: [HistoryEntry] = []
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @State private var engineFilter: EngineFilter = .all
    @State private var sidebarVisible = true
    @State private var showInspector = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            // MARK: - Sidebar
            if sidebarVisible {
                HistorySidebarView(
                    entries: entries,
                    selection: $selectedEntry,
                    searchText: $searchText,
                    engineFilter: $engineFilter
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
        .onAppear(perform: loadEntries)
    }

    // MARK: - Data

    private func loadEntries() {
        entries = TranscriptionHistoryManager.shared.fetchAll()
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
        // TODO: Open engine picker and re-process audio
        print("Re-transcribe entry \(entry.id) with different engine")
    }
}

// MARK: - Previews

#Preview("History Window") {
    HistoryView()
        .frame(width: 900, height: 560)
}
