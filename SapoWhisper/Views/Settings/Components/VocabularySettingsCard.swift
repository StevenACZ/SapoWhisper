import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct VocabularySettingsCard: View {
    private var vocabularyManager = VocabularyManager.shared
    private var polishMemory = AIPolishMemoryManager.shared
    @StateObject private var metricsModel = VocabularyMetricsModel()

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
    @FocusState private var isKeytermFieldFocused: Bool
    @FocusState private var isReplaceFromFieldFocused: Bool

    private let transferManager = SettingsTransferManager.shared

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var replacementValues: [String] {
        vocabularyManager.replacements.sorted { $0.key < $1.key }.map(\.value)
    }

    var body: some View {
        SettingsCard(icon: "text.book.closed", title: "config.vocabulary".localized) {
            VStack(alignment: .leading, spacing: 12) {
                VocabularyMetricsHeader(
                    metrics: metricsModel.metrics,
                    termCount: vocabularyManager.keyterms.count
                )

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
                .animation(Constants.Animation.transition, value: section)

                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundColor(transferMessageIsError ? .red : .secondary)
                }
            }
        }
        .help("settings.vocabulary.desc".localized)
        .onAppear {
            recomputeFilters()
            metricsModel.refreshFromHistory(
                keyterms: vocabularyManager.keyterms,
                replacementValues: replacementValues
            )
        }
        .onChange(of: searchText) { _, _ in recomputeFilters() }
        .onChange(of: vocabularyManager.keyterms) { _, _ in
            recomputeFilters()
            metricsModel.recountTerms(
                keyterms: vocabularyManager.keyterms,
                replacementValues: replacementValues
            )
        }
        .onChange(of: vocabularyManager.replacements) { _, _ in
            recomputeFilters()
            metricsModel.recountTerms(
                keyterms: vocabularyManager.keyterms,
                replacementValues: replacementValues
            )
        }
        .onReceive(
            NotificationCenter.default.publisher(for: TranscriptionHistoryManager.didChangeNotification)
        ) { _ in
            metricsModel.scheduleRefreshFromHistory(
                keyterms: vocabularyManager.keyterms,
                replacementValues: replacementValues
            )
        }
    }

    private func recomputeFilters() {
        let query = normalizedSearchText
        // Alphabetical at view level only — insertion order stays untouched in
        // vocabulary.json, and chips don't churn when usage counts refresh.
        let sortedKeyterms = vocabularyManager.keyterms.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        if query.isEmpty {
            filteredKeyterms = sortedKeyterms
        } else {
            filteredKeyterms = sortedKeyterms.filter {
                $0.localizedCaseInsensitiveContains(query)
            }
        }

        let sorted = vocabularyManager.replacements.sorted {
            $0.key.localizedStandardCompare($1.key) == .orderedAscending
        }
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
        Picker("config.vocabulary".localized, selection: $section.animation(Constants.Animation.transition)) {
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
        .accessibilityLabel("settings.vocabulary.transfer_help".localized)
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
                .accessibilityLabel("common.clear_search".localized)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: - Keywords

    private var keytermsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            keytermAddRow

            newKeytermLimitWarning

            if filteredKeyterms.isEmpty {
                keywordsEmptyState
            } else {
                LazyVGrid(columns: keytermGridColumns, spacing: 6) {
                    ForEach(filteredKeyterms, id: \.self) { term in
                        VocabularyTermRow(
                            term: term,
                            usageCount: metricsModel.termCounts[term.lowercased()]
                        ) {
                            vocabularyManager.removeKeyterm(term)
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(Constants.Animation.springSnap, value: filteredKeyterms)
            }

            Text("config.keyterms_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)

            keytermLimitWarnings
        }
    }

    private var keytermAddRow: some View {
        HStack(spacing: 8) {
            TextField("config.keyterm_placeholder".localized, text: $newKeyterm)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($isKeytermFieldFocused)
                .onSubmit { addKeyterm() }
                .overlay(alignment: .trailing) {
                    if !newKeyterm.isEmpty {
                        Text("\(newKeyterm.count)/\(ElevenLabsKeytermLimits.batchMaxLength)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(newKeytermCounterColor)
                            .padding(.trailing, 6)
                            .transition(.opacity)
                    }
                }

            if !newKeyterm.isEmpty {
                Text("↩")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("vocab.add_return_hint".localized)
                    .transition(.opacity)
            }

            Button("config.add".localized) { addKeyterm() }
                .buttonStyle(.bordered)
                .font(.caption)
                .disabled(newKeyterm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .animation(Constants.Animation.hover, value: newKeyterm.isEmpty)
    }

    /// Live limit feedback while typing, before the term is saved. Over-limit
    /// terms can still be added (matching import behavior) — they are skipped
    /// at request time on the affected engine, never dropped from the list.
    @ViewBuilder
    private var newKeytermLimitWarning: some View {
        let trimmed = newKeyterm.trimmingCharacters(in: .whitespacesAndNewlines)

        if exceedsBatchLimits(trimmed) {
            Label("vocab.add_over_batch".localized, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else if exceedsRealtimeLimit(trimmed) {
            Label("vocab.add_over_realtime".localized, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private var newKeytermCounterColor: Color {
        let trimmed = newKeyterm.trimmingCharacters(in: .whitespacesAndNewlines)
        if exceedsBatchLimits(trimmed) {
            return Color.sapoError
        }
        if exceedsRealtimeLimit(trimmed) {
            return .orange
        }
        return .secondary
    }

    private func exceedsBatchLimits(_ term: String) -> Bool {
        term.count > ElevenLabsKeytermLimits.batchMaxLength
            || term.split(separator: " ").count > ElevenLabsKeytermLimits.batchMaxWords
    }

    private func exceedsRealtimeLimit(_ term: String) -> Bool {
        term.count > ElevenLabsKeytermLimits.realtimeMaxLength
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

    @ViewBuilder
    private var keywordsEmptyState: some View {
        if !normalizedSearchText.isEmpty {
            searchEmptyState
        } else {
            VocabularyEmptyState(
                icon: "text.book.closed",
                title: "vocab.empty.keywords_title".localized,
                subtitle: "vocab.empty.keywords_subtitle".localized,
                actionTitle: "vocab.empty.add_first".localized,
                action: { isKeytermFieldFocused = true }
            )
        }
    }

    // MARK: - Corrections

    private var replacementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("config.replace_from".localized, text: $newReplaceFrom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 140)
                    .focused($isReplaceFromFieldFocused)

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

            Toggle(isOn: replacementTargetsInRecognitionHintsBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("config.replacement_targets_as_hints".localized)
                        .font(.caption.weight(.medium))
                    Text("config.replacement_targets_as_hints_desc".localized)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if normalizedSearchText.isEmpty, !polishMemory.pendingSuggestions.isEmpty {
                learnedCorrectionsSection
            }

            if filteredReplacements.isEmpty {
                correctionsEmptyState
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(filteredReplacements, id: \.key) { replacement in
                        VocabularyReplacementRow(
                            original: replacement.key,
                            replacement: replacement.value,
                            isAISuggested: replacementWasSuggestedByAI(
                                original: replacement.key,
                                replacement: replacement.value
                            ),
                            usageCount: metricsModel.termCounts[replacement.value.lowercased()]
                        ) {
                            vocabularyManager.removeReplacement(forKey: replacement.key)
                        }
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .animation(Constants.Animation.springSnap, value: filteredReplacements.map(\.key))
            }

            Text("config.replacements_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var replacementTargetsInRecognitionHintsBinding: Binding<Bool> {
        Binding(
            get: { vocabularyManager.includeReplacementTargetsInRecognitionHints },
            set: { vocabularyManager.setIncludeReplacementTargetsInRecognitionHints($0) }
        )
    }

    private var learnedCorrectionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("vocab.learning.title".localized, systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.sapoGreenText)

                Spacer(minLength: 0)

                Text("vocab.learning.badge".localized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.sapoGreenText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.sapoGreen.opacity(0.12))
                    )
                    .help("vocab.learning.badge_help".localized)
            }

            LazyVStack(spacing: 6) {
                ForEach(polishMemory.pendingSuggestions) { suggestion in
                    LearnedCorrectionSuggestionRow(
                        suggestion: suggestion,
                        onAccept: { acceptSuggestion(suggestion) },
                        onEdit: { editSuggestion(suggestion) },
                        onReject: { polishMemory.rejectSuggestion(id: suggestion.id) }
                    )
                }
            }

            Text("vocab.learning.desc".localized)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var correctionsEmptyState: some View {
        if !normalizedSearchText.isEmpty {
            searchEmptyState
        } else {
            VocabularyEmptyState(
                icon: "arrow.left.arrow.right",
                title: "vocab.empty.corrections_title".localized,
                subtitle: "vocab.empty.corrections_subtitle".localized,
                actionTitle: "vocab.empty.add_first".localized,
                action: { isReplaceFromFieldFocused = true }
            )
        }
    }

    private var searchEmptyState: some View {
        VocabularyEmptyState(
            icon: "magnifyingglass",
            title: "vocab.empty.search_title".localized(normalizedSearchText),
            actionTitle: "vocab.empty.clear_search".localized,
            action: { searchText = "" }
        )
    }

    // MARK: - Actions

    private func addKeyterm() {
        vocabularyManager.addKeyterm(newKeyterm)
        newKeyterm = ""
    }

    private func addReplacement() {
        vocabularyManager.addReplacement(from: newReplaceFrom, to: newReplaceTo)
        newReplaceFrom = ""
        newReplaceTo = ""
    }

    private func acceptSuggestion(_ suggestion: AIPolishCorrectionSuggestion) {
        guard let accepted = polishMemory.acceptSuggestion(id: suggestion.id) else { return }
        vocabularyManager.addReplacement(from: accepted.from, to: accepted.to)
        recomputeFilters()
    }

    private func editSuggestion(_ suggestion: AIPolishCorrectionSuggestion) {
        newReplaceFrom = suggestion.from
        newReplaceTo = suggestion.to
        isReplaceFromFieldFocused = true
    }

    private func replacementWasSuggestedByAI(original: String, replacement: String) -> Bool {
        let originalKey = normalizedSuggestionKey(original)
        let replacementKey = normalizedSuggestionKey(replacement)
        return polishMemory.acceptedSuggestions.contains { suggestion in
            normalizedSuggestionKey(suggestion.from) == originalKey
                && normalizedSuggestionKey(suggestion.to) == replacementKey
        }
    }

    private func normalizedSuggestionKey(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[\s._,-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

private struct LearnedCorrectionSuggestionRow: View {
    let suggestion: AIPolishCorrectionSuggestion
    let onAccept: () -> Void
    let onEdit: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VocabularyMonospacedText(text: suggestion.from, foregroundColor: .secondary)

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundColor(.secondary)

            VocabularyMonospacedText(text: suggestion.to)

            if suggestion.occurrences > 1 {
                Text("×\(suggestion.occurrences)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("vocab.learning.occurrences".localized(String(suggestion.occurrences)))
            }

            Spacer(minLength: 0)

            Button(action: onAccept) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.sapoGreen)
            }
            .buttonStyle(.plain)
            .help("vocab.learning.accept".localized)
            .accessibilityLabel("vocab.learning.accept".localized)

            Button(action: onEdit) {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("vocab.learning.edit".localized)
            .accessibilityLabel("vocab.learning.edit".localized)

            Button(action: onReject) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("vocab.learning.ignore".localized)
            .accessibilityLabel("vocab.learning.ignore".localized)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.sapoGreen.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.sapoGreen.opacity(0.22), lineWidth: 1)
        )
    }
}
