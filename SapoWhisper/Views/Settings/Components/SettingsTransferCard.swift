//
//  SettingsTransferCard.swift
//  SapoWhisper
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

struct SettingsTransferCard: View {
    let viewModel: SapoWhisperViewModel

    @State private var importDocument: SettingsTransferDocument?
    @State private var selectedImportSections: Set<SettingsTransferSection> = []
    @State private var transferMessage: String?
    @State private var transferMessageIsError = false

    private let transferManager = SettingsTransferManager.shared

    var body: some View {
        SettingsCard(icon: "arrow.up.arrow.down.square.fill", title: "settings.transfer.title".localized) {
            VStack(alignment: .leading, spacing: 12) {
                Text("settings.transfer.desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 10) {
                    Button(action: exportSettings) {
                        Label("settings.transfer.export".localized, systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)

                    Button(action: beginImport) {
                        Label("settings.transfer.import".localized, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Constants.Colors.sapoGreen)
                }

                if let transferMessage {
                    Text(transferMessage)
                        .font(.caption)
                        .foregroundColor(transferMessageIsError ? .red : .secondary)
                }
            }
        }
        .sheet(item: $importDocument) { document in
            SettingsImportOptionsSheet(
                document: document,
                selectedSections: $selectedImportSections,
                onCancel: {
                    importDocument = nil
                },
                onImport: {
                    finishImport(document)
                }
            )
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "SapoWhisper-Settings-\(fileDateStamp()).json"
        panel.message = "settings.transfer.export_panel_message".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try transferManager.encodedSettings()
            try data.write(to: url, options: .atomic)
            setMessage("settings.transfer.export_success".localized, isError: false)
            SapoLog.settings.info("Settings exported")
        } catch {
            setMessage(error.localizedDescription, isError: true)
        }
    }

    private func beginImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "settings.transfer.import_panel_message".localized

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let document = try transferManager.decodedDocument(from: data)
            selectedImportSections = transferManager.defaultImportSections(for: document)
            importDocument = document
        } catch {
            setMessage(error.localizedDescription, isError: true)
        }
    }

    private func finishImport(_ document: SettingsTransferDocument) {
        do {
            try transferManager.importDocument(document, sections: selectedImportSections)
            applyRuntimeChanges(for: selectedImportSections)
            setMessage("settings.transfer.import_success".localized, isError: false)
            let importedSections = selectedImportSections.map(\.rawValue).joined(separator: ",")
            SapoLog.settings.info("Settings imported sections=\(importedSections, privacy: .public)")
            importDocument = nil
        } catch {
            setMessage(error.localizedDescription, isError: true)
        }
    }

    private func applyRuntimeChanges(for sections: Set<SettingsTransferSection>) {
        let defaults = UserDefaults.standard

        if sections.contains(.engine) {
            if let model = WhisperKitModel(rawValue: defaults.string(forKey: Constants.StorageKeys.whisperKitModel) ?? "") {
                viewModel.setWhisperKitModel(model)
            }
            if let mode = DeepgramTranscriptionMode(
                rawValue: defaults.string(forKey: Constants.StorageKeys.deepgramTranscriptionMode) ?? ""
            ) {
                viewModel.setDeepgramMode(mode)
            }
            if let engine = TranscriptionEngine(rawValue: defaults.string(forKey: Constants.StorageKeys.transcriptionEngine) ?? "") {
                viewModel.setEngine(engine)
            }
        }
    }

    private func setMessage(_ message: String, isError: Bool) {
        transferMessage = message
        transferMessageIsError = isError
    }

    private func fileDateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}

private struct SettingsImportOptionsSheet: View {
    let document: SettingsTransferDocument
    @Binding var selectedSections: Set<SettingsTransferSection>
    let onCancel: () -> Void
    let onImport: () -> Void

    private var availableSections: [SettingsTransferSection] {
        SettingsTransferManager.shared.availableSections(in: document)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.transfer.import_options_title".localized)
                    .font(.headline)
                Text("settings.transfer.import_options_desc".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(availableSections) { section in
                    Toggle(isOn: sectionBinding(section)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.titleKey.localized)
                                .font(.subheadline.weight(.medium))
                            Text(section.descriptionKey.localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("cancel".localized, action: onCancel)
                Button("settings.transfer.import_selected".localized, action: onImport)
                    .buttonStyle(.borderedProminent)
                    .tint(Constants.Colors.sapoGreen)
                    .disabled(selectedSections.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 430)
    }

    private func sectionBinding(_ section: SettingsTransferSection) -> Binding<Bool> {
        Binding(
            get: { selectedSections.contains(section) },
            set: { isEnabled in
                if isEnabled {
                    selectedSections.insert(section)
                } else {
                    selectedSections.remove(section)
                }
            }
        )
    }
}
