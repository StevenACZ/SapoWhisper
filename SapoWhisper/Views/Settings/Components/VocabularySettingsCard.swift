import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct VocabularySettingsCard: View {
    @ObservedObject private var vocabularyManager = VocabularyManager.shared

    /// Keywords and corrections live in separate segments so the tab shows
    /// one focused list at a time instead of one long wall of content.
    private enum VocabularySection: String, CaseIterable, Identifiable {
        case keywords
        case corrections

        var id: String { rawValue }
    }

    @State private var section: VocabularySection = .keywords
    @State private var newKeyterm = ""
    @State private var newReplaceFrom = ""
    @State private var newReplaceTo = ""
    @State private var searchText = ""
    @State private var transferMessage: String?
    @State private var transferMessageIsError = false
    @State private var filteredKeyterms: [String] = []
    @State private var filteredReplacements: [(key: String, value: String)] = []

    private let transferManager = SettingsTransferManager.shared

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        SettingsCard(icon: "text.book.closed", title: "config.vocabulary".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.vocabulary.desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    sectionPicker
                    transferMenu
                }

                searchField

                Group {
                    if section == .keywords {
                        keytermsSection
                            .transition(
                                .opacity.combined(with: .offset(x: -14))
                            )
                    } else {
                        replacementsSection
                            .transition(
                                .opacity.combined(with: .offset(x: 14))
                            )
                    }
                }
                .animation(.smooth(duration: 0.28), value: section)

                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundColor(transferMessageIsError ? .red : .secondary)
                }
            }
        }
        .onAppear(perform: recomputeFilters)
        .onChange(of: searchText) { _, _ in recomputeFilters() }
        .onChange(of: vocabularyManager.keyterms) { _, _ in recomputeFilters() }
        .onChange(of: vocabularyManager.replacements) { _, _ in recomputeFilters() }
    }

    private func recomputeFilters() {
        let query = normalizedSearchText
        if query.isEmpty {
            filteredKeyterms = vocabularyManager.keyterms
        } else {
            filteredKeyterms = vocabularyManager.keyterms.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
        }

        let sorted = vocabularyManager.replacements.sorted { $0.key < $1.key }
        if query.isEmpty {
            filteredReplacements = sorted
        } else {
            filteredReplacements = sorted.filter {
                $0.key.localizedCaseInsensitiveContains(query)
                    || $0.value.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var sectionPicker: some View {
        Picker("config.vocabulary".localized, selection: $section.animation(.smooth(duration: 0.28))) {
            Text("\("config.keyterms".localized) (\(vocabularyManager.keyterms.count))")
                .tag(VocabularySection.keywords)
            Text("\("config.replacements".localized) (\(vocabularyManager.replacements.count))")
                .tag(VocabularySection.corrections)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var transferMenu: some View {
        Menu {
            Button(action: exportVocabulary) {
                Label("settings.vocabulary.export".localized, systemImage: "square.and.arrow.down")
            }
            Button(action: importVocabulary) {
                Label("settings.vocabulary.import".localized, systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("settings.vocabulary.transfer_help".localized)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("settings.vocabulary.search".localized, text: $searchText)
                .textFieldStyle(.plain)

            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }

    private var keytermsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("config.keyterm_placeholder".localized, text: $newKeyterm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addKeyterm() }

                Button("config.add".localized) { addKeyterm() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(newKeyterm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if filteredKeyterms.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: keytermGridColumns, spacing: 6) {
                    ForEach(filteredKeyterms, id: \.self) { term in
                        VocabularyTermRow(term: term) {
                            vocabularyManager.removeKeyterm(term)
                        }
                    }
                }
                .animation(.spring(duration: 0.3), value: filteredKeyterms)
            }

            Text("config.keyterms_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            keytermLimitWarnings
        }
    }

    /// Over-limit terms are skipped at request time; surface that here instead
    /// of dropping them silently (ElevenLabs batch: ≤50 chars and ≤5 words;
    /// realtime: ≤20 chars).
    @ViewBuilder
    private var keytermLimitWarnings: some View {
        let violations = vocabularyManager.elevenLabsLimitViolations()

        if violations.batch > 0 {
            Label(
                "config.keyterm_limit_batch".localized(String(violations.batch)),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }

        if violations.realtime > 0 {
            Label(
                "config.keyterm_limit_realtime".localized(String(violations.realtime)),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private var keytermGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 6)]
    }

    private var replacementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("config.replace_from".localized, text: $newReplaceFrom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 140)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("config.replace_to".localized, text: $newReplaceTo)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addReplacement() }

                Button("config.add".localized) { addReplacement() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(
                        newReplaceFrom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || newReplaceTo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }

            if filteredReplacements.isEmpty {
                emptyState
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(filteredReplacements, id: \.key) { replacement in
                        VocabularyReplacementRow(
                            original: replacement.key,
                            replacement: replacement.value
                        ) {
                            vocabularyManager.removeReplacement(forKey: replacement.key)
                        }
                    }
                }
                .animation(.spring(duration: 0.3), value: filteredReplacements.map(\.key))
            }

            Text("config.replacements_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var emptyState: some View {
        Text("settings.vocabulary.empty".localized)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
    }

    private func addKeyterm() {
        vocabularyManager.addKeyterm(newKeyterm)
        newKeyterm = ""
    }

    private func addReplacement() {
        vocabularyManager.addReplacement(from: newReplaceFrom, to: newReplaceTo)
        newReplaceFrom = ""
        newReplaceTo = ""
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SapoWhisper-Vocabulary-\(fileDateStamp()).json"
        panel.message = "settings.vocabulary.export_panel_message".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try transferManager.encodedVocabulary()
            try data.write(to: url, options: .atomic)
            setTransferMessage("settings.vocabulary.export_success".localized, isError: false)
            SapoLog.settings.info("Vocabulary exported")
        } catch {
            setTransferMessage(error.localizedDescription, isError: true)
        }
    }

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "settings.vocabulary.import_panel_message".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let document = try transferManager.decodedDocument(from: data)
            try transferManager.importVocabulary(from: document)
            setTransferMessage("settings.vocabulary.import_success".localized, isError: false)
            SapoLog.settings.info("Vocabulary imported")
        } catch {
            setTransferMessage(error.localizedDescription, isError: true)
        }
    }

    private func setTransferMessage(_ message: String, isError: Bool) {
        transferMessage = message
        transferMessageIsError = isError
    }

    private func fileDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}

private struct VocabularyTermRow: View {
    let term: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VocabularyMonospacedText(text: term)

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(7)
    }
}

private struct VocabularyReplacementRow: View {
    let original: String
    let replacement: String
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VocabularyMonospacedText(text: original, foregroundColor: .secondary)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)

            VocabularyMonospacedText(text: replacement)

            Spacer(minLength: 0)

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(7)
    }
}

private struct VocabularyMonospacedText: View {
    let text: String
    var foregroundColor: Color = .primary

    @State private var availableWidth: CGFloat = 0

    private static let measurementFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    private var isTruncated: Bool {
        guard availableWidth > 0 else { return false }
        let intrinsicWidth = (text as NSString).size(withAttributes: [
            .font: Self.measurementFont
        ]).width
        return intrinsicWidth > availableWidth + 0.5
    }

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(foregroundColor)
            .lineLimit(1)
            .truncationMode(.middle)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { availableWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            availableWidth = newValue
                        }
                }
            )

        if isTruncated {
            label.help(text)
        } else {
            label
        }
    }
}
