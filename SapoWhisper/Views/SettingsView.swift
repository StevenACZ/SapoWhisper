//
//  SettingsView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Carbon
import ServiceManagement

/// Vista de configuración completa de la aplicación
/// Se abre desde el botón "Configuración" en el menú
struct SettingsView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) private var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) private var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true
    @AppStorage(Constants.StorageKeys.transcriptionEngine) private var selectedEngine = TranscriptionEngine.appleOnline.rawValue
    @AppStorage(Constants.StorageKeys.whisperKitModel) private var selectedWhisperModel = WhisperKitModel.small.rawValue

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared

    private var currentEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: selectedEngine) ?? .appleOnline
    }

    private var currentWhisperKitModel: WhisperKitModel {
        WhisperKitModel(rawValue: selectedWhisperModel) ?? .small
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Contenido
            Group {
                if selectedTab == 0 {
                    settingsTab
                } else {
                    infoTab
                }
            }

            Divider()

            // Footer
            footerSection
        }
        .frame(width: 480, height: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // Picker en el centro de la barra de título
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
                    Text("config.tab_settings".localized).tag(0)
                    Text("config.tab_info".localized).tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            // Botón cerrar a la derecha
            ToolbarItem(placement: .confirmationAction) {
                Button("close".localized) {
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Settings Tab

    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Idioma de la App
                appLanguageCard

                // Motor de transcripcion
                transcriptionEngineCard

                // Modelo de WhisperKit (solo si esta en modo local)
                if currentEngine == .whisperLocal {
                    whisperKitModelCard
                }

                // Microfono
                microphoneCard

                // Idioma de entrada
                languageSelectionCard

                // Hotkey
                hotkeyCard

                // Comportamiento
                behaviorCard
            }
            .padding()
        }
        .onAppear {
            audioDeviceManager.refreshDevices()
        }
    }

    // MARK: - App Language Card

    private var appBinding: Binding<String> {
        Binding(
            get: { LocalizationManager.shared.language },
            set: { LocalizationManager.shared.language = $0 }
        )
    }

    private var appLanguageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("config.app_language".localized, systemImage: "gearshape.2")
                .font(.headline)

            HStack(spacing: 12) {
                LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: appBinding)
                LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: appBinding)
            }

            Text("config.app_language_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - Transcription Engine Card

    private var transcriptionEngineCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("config.engine".localized, systemImage: "cpu")
                .font(.headline)

            VStack(spacing: 8) {
                ForEach(TranscriptionEngine.allCases) { engine in
                    EngineButton(
                        engine: engine,
                        isSelected: currentEngine == engine,
                        isLoading: engine == .whisperLocal && viewModel.isLoadingWhisperKit,
                        loadingProgress: viewModel.whisperKitLoadingProgress,
                        loadingMessage: viewModel.whisperKitLoadingMessage
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedEngine = engine.rawValue
                            viewModel.setEngine(engine)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - WhisperKit Model Card

    private var whisperKitModelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("config.whisper_model".localized, systemImage: "square.stack.3d.up")
                    .font(.headline)

                Spacer()

                if viewModel.whisperKitTranscriber.isModelLoaded {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.sapoGreen)
                        Text(viewModel.whisperKitTranscriber.loadedModelName ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if viewModel.isLoadingWhisperKit {
                VStack(spacing: 8) {
                    ProgressView(value: viewModel.whisperKitLoadingProgress)
                        .progressViewStyle(.linear)
                        .tint(viewModel.whisperKitTranscriber.loadingState == .downloading ? .blue : .sapoGreen)

                    HStack(spacing: 6) {
                        // Icono segun estado
                        if viewModel.whisperKitTranscriber.loadingState == .downloading {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                        } else if viewModel.whisperKitTranscriber.loadingState == .prewarming {
                            Image(systemName: "cpu.fill")
                                .foregroundColor(.sapoGreen)
                                .font(.caption)
                        }
                        
                        Text(viewModel.whisperKitLoadingMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            VStack(spacing: 8) {
                ForEach(WhisperKitModel.allCases) { model in
                    let isDownloaded = viewModel.whisperKitTranscriber.isModelDownloaded(model)
                    let downloadedSize = viewModel.whisperKitTranscriber.downloadedModelSize(model)
                    
                    WhisperModelButton(
                        model: model,
                        isSelected: currentWhisperKitModel == model,
                        isLoading: viewModel.isLoadingWhisperKit && currentWhisperKitModel == model,
                        isDownloaded: isDownloaded,
                        downloadedSize: downloadedSize,
                        action: {
                            selectedWhisperModel = model.rawValue
                            viewModel.setWhisperKitModel(model)
                        },
                        onDelete: isDownloaded ? {
                            deleteModel(model)
                        } : nil
                    )
                }
            }

            // Mostrar espacio total usado por modelos
            let downloadedModels = viewModel.whisperKitTranscriber.getDownloadedModelsInfo()
            if !downloadedModels.isEmpty {
                let totalSize = downloadedModels.reduce(0) { $0 + $1.size }
                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundColor(.secondary)
                    Text("config.space_used".localized(WhisperKitTranscriber.formatBytes(totalSize)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 4)
            }

            Text("config.models_download_auto".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - Microphone Card

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.microphone".localized, systemImage: "mic.fill")
                .font(.headline)

            Picker("settings.microphone_desc".localized, selection: $selectedMicrophone) {
                ForEach(audioDeviceManager.availableDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - Language Selection Card

    private var languageSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.input_language".localized, systemImage: "globe")
                .font(.headline)

            HStack(spacing: 12) {
                LanguageButton(name: "lang.spanish".localized, flag: "🇪🇸", languageCode: "es", selectedLanguage: $selectedLanguage)
                LanguageButton(name: "lang.english".localized, flag: "🇺🇸", languageCode: "en", selectedLanguage: $selectedLanguage)
                LanguageButton(name: "lang.auto".localized, flag: "🌐", languageCode: "auto", selectedLanguage: $selectedLanguage)
            }

            Text("settings.input_language_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - Hotkey Card

    @State private var isRecordingHotkey = false

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.hotkeys".localized, systemImage: "keyboard")
                .font(.headline)

            HotkeyRecorderView(
                keyCode: $hotkeyKeyCode,
                modifiers: $hotkeyModifiers,
                isRecording: $isRecordingHotkey,
                onHotkeyChanged: { keyCode, modifiers in
                    updateHotkey(keyCode: keyCode, modifiers: modifiers)
                }
            )
            .frame(height: 36)

            Text("config.hotkey_instruction".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    // MARK: - Behavior Card

    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("settings.behavior".localized, systemImage: "gearshape")
                .font(.headline)

            Toggle(isOn: $autoPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.auto_paste".localized)
                    Text("settings.auto_paste_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.launch_at_login".localized)
                    Text("settings.launch_at_login_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .onChange(of: launchAtLogin) { _, newValue in
                setLaunchAtLogin(enabled: newValue)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
    
    // MARK: - Launch at Login
    
    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                print("✅ SapoWhisper registrado para iniciar al arrancar")
            } else {
                try SMAppService.mainApp.unregister()
                print("✅ SapoWhisper des-registrado del arranque")
            }
        } catch {
            print("❌ Error al configurar Launch at Login: \(error.localizedDescription)")
            // Revertir el estado del toggle si hay error
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Hotkey Helpers

    private var currentHotkeyDescription: String {
        var parts: [String] = []

        if hotkeyModifiers & controlKey != 0 { parts.append("⌃") }
        if hotkeyModifiers & optionKey != 0 { parts.append("⌥") }
        if hotkeyModifiers & shiftKey != 0 { parts.append("⇧") }
        if hotkeyModifiers & cmdKey != 0 { parts.append("⌘") }

        switch hotkeyKeyCode {
        case 49: parts.append("Space")
        case 36: parts.append("Return")
        default: parts.append("Key\(hotkeyKeyCode)")
        }

        return parts.joined(separator: " + ")
    }

    private func isHotkeySelected(keyCode: Int, modifiers: Int) -> Bool {
        hotkeyKeyCode == keyCode && hotkeyModifiers == modifiers
    }

    private func updateHotkey(keyCode: Int, modifiers: Int) {
        hotkeyKeyCode = keyCode
        hotkeyModifiers = modifiers
        // Usa la versión que mantiene el callback existente
        HotkeyManager.shared.updateHotkey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    // MARK: - Model Management

    private func deleteModel(_ model: WhisperKitModel) {
        // Si el modelo a borrar es el actualmente seleccionado, primero cambiar a Apple Speech
        if currentWhisperKitModel == model && viewModel.whisperKitTranscriber.isModelLoaded {
            viewModel.setEngine(.appleOnline)
        }
        
        let success = viewModel.whisperKitTranscriber.deleteDownloadedModel(model)
        if success {
            print("✅ Modelo \(model.displayName) borrado exitosamente")
        } else {
            print("❌ Error al borrar modelo \(model.displayName)")
        }
    }

    // MARK: - Info Tab

    private var infoTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Hero section
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 90, height: 90)

                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(spacing: 4) {
                        Text("app_name".localized)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("config.subtitle_info".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 8)

                // Cómo funciona
                InfoSection(
                    icon: "questionmark.circle.fill",
                    title: "info.how_to_title".localized,
                    content: "info.how_to_body".localized
                )

                // Privacidad
                InfoSection(
                    icon: "lock.shield.fill",
                    title: "info.privacy_title".localized,
                    content: "info.privacy_body".localized
                )

                // Permisos
                InfoSection(
                    icon: "hand.raised.fill",
                    title: "info.permissions_title".localized,
                    content: "info.permissions_body".localized
                )
                
                // Acerca de
                VStack(spacing: 8) {
                    Divider()
                        .frame(width: 200)
                    
                    VStack(spacing: 8) {
                        Text("made_by".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Button {
                            if let url = URL(string: Constants.githubURL) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("settings.view_github".localized, systemImage: "link")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding()
        }
    }
    
    // MARK: - Footer
    
    private var footerSection: some View {
        HStack {
            // Versión
            Text("v\(Constants.appVersion)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button("close".localized) {
                dismiss()
            }
            .keyboardShortcut(.escape)
            .buttonStyle(.borderedProminent)
            .tint(.sapoGreen)
        }
        .padding()
    }
}

// MARK: - Supporting Views

struct LanguageButton: View {
    let name: String
    let flag: String
    let languageCode: String
    @Binding var selectedLanguage: String

    var isSelected: Bool {
        selectedLanguage == languageCode
    }

    var body: some View {
        Button(action: {
            selectedLanguage = languageCode
        }) {
            HStack(spacing: 4) {
                Text(flag)
                Text(name)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.windowBackgroundColor))
            .foregroundColor(isSelected ? .sapoGreen : .primary)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.sapoGreen : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hotkey Recorder View

struct HotkeyRecorderView: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var isRecording: Bool
    var onHotkeyChanged: (Int, Int) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.delegate = context.coordinator
        view.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {
        nsView.updateDisplay(keyCode: keyCode, modifiers: modifiers)
        nsView.isRecording = isRecording
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, HotkeyRecorderDelegate {
        var parent: HotkeyRecorderView

        init(_ parent: HotkeyRecorderView) {
            self.parent = parent
        }

        func hotkeyRecorded(keyCode: Int, modifiers: Int) {
            parent.keyCode = keyCode
            parent.modifiers = modifiers
            parent.isRecording = false
            parent.onHotkeyChanged(keyCode, modifiers)
        }

        func recordingStateChanged(_ isRecording: Bool) {
            parent.isRecording = isRecording
        }
    }
}

protocol HotkeyRecorderDelegate: AnyObject {
    func hotkeyRecorded(keyCode: Int, modifiers: Int)
    func recordingStateChanged(_ isRecording: Bool)
}

class HotkeyRecorderNSView: NSView {
    weak var delegate: HotkeyRecorderDelegate?
    var isRecording = false {
        didSet {
            needsDisplay = true
        }
    }

    private var displayKeyCode: Int = 49
    private var displayModifiers: Int = 2048 // optionKey

    private var currentModifiers: NSEvent.ModifierFlags = []

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 8
    }

    func updateDisplay(keyCode: Int, modifiers: Int) {
        displayKeyCode = keyCode
        displayModifiers = modifiers
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bgColor: NSColor = isRecording ? NSColor.systemGreen.withAlphaComponent(0.2) : NSColor.controlBackgroundColor
        bgColor.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        path.fill()

        // Border
        let borderColor: NSColor = isRecording ? NSColor.systemGreen : NSColor.separatorColor
        borderColor.setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        // Text
        let text = isRecording ? "Presiona tu atajo..." : hotkeyDescription(keyCode: displayKeyCode, modifiers: displayModifiers)
        let textColor: NSColor = isRecording ? .secondaryLabelColor : .labelColor

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]

        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        delegate?.recordingStateChanged(true)
        currentModifiers = []
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Necesita al menos un modificador
        guard !modifiers.isEmpty else {
            NSSound.beep()
            return
        }

        let keyCode = Int(event.keyCode)
        let modifierValue = carbonModifiers(from: modifiers)

        displayKeyCode = keyCode
        displayModifiers = modifierValue
        isRecording = false

        delegate?.hotkeyRecorded(keyCode: keyCode, modifiers: modifierValue)
        delegate?.recordingStateChanged(false)
        needsDisplay = true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        currentModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var result = 0
        if flags.contains(.command) { result |= cmdKey }
        if flags.contains(.option) { result |= optionKey }
        if flags.contains(.control) { result |= controlKey }
        if flags.contains(.shift) { result |= shiftKey }
        return result
    }

    private func hotkeyDescription(keyCode: Int, modifiers: Int) -> String {
        var parts: [String] = []

        if modifiers & controlKey != 0 { parts.append("⌃") }
        if modifiers & optionKey != 0 { parts.append("⌥") }
        if modifiers & shiftKey != 0 { parts.append("⇧") }
        if modifiers & cmdKey != 0 { parts.append("⌘") }

        parts.append(keyName(for: keyCode))

        return parts.joined(separator: " ")
    }

    private func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 48: return "Tab"
        case 51: return "Delete"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        default: return "Key\(keyCode)"
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 200, height: 36)
    }
}

struct InfoSection: View {
    let icon: String
    let title: String
    let content: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            
            Text(content)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
}

// MARK: - Engine Button

struct EngineButton: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    let isLoading: Bool
    let loadingProgress: Double
    let loadingMessage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icono
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.controlBackgroundColor))
                        .frame(width: 40, height: 40)

                    Image(systemName: engine.icon)
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? .sapoGreen : .secondary)
                }

                // Texto
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(engine.displayName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        if engine == .whisperLocal {
                            Text("badge.recommended".localized)
                                .font(.caption2)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.sapoGreen)
                                .cornerRadius(4)
                        }
                    }

                    Text(engine.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Indicador de seleccion o carga
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.sapoGreen)
                        .font(.system(size: 20))
                } else {
                    Circle()
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1.5)
                        .frame(width: 20, height: 20)
                }
            }
            .padding(12)
            .background(isSelected ? Color.sapoGreen.opacity(0.1) : Color(NSColor.windowBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.sapoGreen.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - WhisperKit Model Button

struct WhisperModelButton: View {
    let model: WhisperKitModel
    let isSelected: Bool
    let isLoading: Bool
    let isDownloaded: Bool
    let downloadedSize: Int64?
    let onSelect: () -> Void
    let onDelete: (() -> Void)?

    init(model: WhisperKitModel,
         isSelected: Bool,
         isLoading: Bool,
         isDownloaded: Bool = false,
         downloadedSize: Int64? = nil,
         action: @escaping () -> Void,
         onDelete: (() -> Void)? = nil) {
        self.model = model
        self.isSelected = isSelected
        self.isLoading = isLoading
        self.isDownloaded = isDownloaded
        self.downloadedSize = downloadedSize
        self.onSelect = action
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 12) {
            // Boton principal (seleccionar modelo)
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    // Radio button
                    ZStack {
                        Circle()
                            .stroke(isSelected ? Color.sapoGreen : Color.secondary.opacity(0.3), lineWidth: 2)
                            .frame(width: 20, height: 20)

                        if isSelected {
                            Circle()
                                .fill(Color.sapoGreen)
                                .frame(width: 12, height: 12)
                        }
                    }

                    // Info del modelo
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(model.displayName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)

                            if model.isRecommended {
                                Text(model == .small ? "badge.balance".localized : "badge.pro".localized)
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(model == .small ? Color.blue : Color.purple)
                                    .cornerRadius(3)
                            }

                            // Indicador de descargado
                            if isDownloaded {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.sapoGreen)
                            }
                        }

                        HStack(spacing: 8) {
                            // Mostrar tamano real si esta descargado, sino el estimado
                            if isDownloaded, let size = downloadedSize {
                                Text(WhisperKitTranscriber.formatBytes(size))
                                    .font(.caption)
                                    .foregroundColor(.sapoGreen)
                            } else {
                                Text(model.fileSize)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Text("•")
                                .foregroundColor(.secondary)

                            Text(model.speed)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text("•")
                                .foregroundColor(.secondary)

                            // Estrellas de precision
                            HStack(spacing: 1) {
                                ForEach(0..<5) { i in
                                    Image(systemName: i < model.accuracy ? "star.fill" : "star")
                                        .font(.system(size: 8))
                                        .foregroundColor(i < model.accuracy ? .yellow : .secondary.opacity(0.3))
                                }
                            }
                        }
                    }

                    Spacer()

                    // Indicador de estado
                    if isLoading {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if !isDownloaded {
                        // Mostrar icono de descarga si no esta descargado
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.5))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoading)

            // Boton de borrar (solo si esta descargado)
            if isDownloaded, let deleteAction = onDelete {
                Button(action: deleteAction) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("model.delete_tooltip".localized)
            }
        }
        .padding(10)
        .background(isSelected ? Color.sapoGreen.opacity(0.08) : Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.sapoGreen.opacity(0.4) : Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

#Preview {
    SettingsView(viewModel: SapoWhisperViewModel())
}
