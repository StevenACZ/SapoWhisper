//
//  ModelDownloadView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import Carbon

/// Vista para gestionar la configuración de transcripción
struct ModelDownloadView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0

    @AppStorage(Constants.StorageKeys.language) private var selectedLanguage = "es"
    @AppStorage(Constants.StorageKeys.selectedMicrophone) private var selectedMicrophone = "default"
    @AppStorage(Constants.StorageKeys.hotkeyKeyCode) private var hotkeyKeyCode: Int = Int(Constants.Hotkey.defaultKeyCode)
    @AppStorage(Constants.StorageKeys.hotkeyModifiers) private var hotkeyModifiers: Int = Int(Constants.Hotkey.defaultModifiers)
    @AppStorage(Constants.StorageKeys.autoPaste) private var autoPaste = true
    @AppStorage(Constants.StorageKeys.playSound) private var playSound = true

    @StateObject private var audioDeviceManager = AudioDeviceManager.shared
    
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
                    Text("Ajustes").tag(0)
                    Text("Info").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 140)
            }

            // Botón cerrar a la derecha
            ToolbarItem(placement: .confirmationAction) {
                Button("Cerrar") {
                    dismiss()
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 16) {
            // Icono del sapo
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
            
            // Título y descripción
            VStack(spacing: 4) {
                Text("Configuración de Voz")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("SapoWhisper usa el reconocimiento de voz de Apple para transcribir tu audio.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .padding(.vertical, 20)
    }
    
    // MARK: - Models Tab
    
    private var modelsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Estado actual
                currentStatusCard
                
                // Idiomas disponibles
                languagesCard
                
                // Modelos de Whisper (para futuro)
                whisperModelsCard
            }
            .padding()
        }
    }
    
    private var currentStatusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Estado Actual", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundColor(.sapoGreen)
            
            HStack(spacing: 16) {
                StatusItem(
                    icon: "mic.fill",
                    title: "Micrófono",
                    status: "Listo",
                    color: .sapoGreen
                )
                
                StatusItem(
                    icon: "waveform",
                    title: "Transcripción",
                    status: viewModel.transcriber.isModelLoaded ? "Activo" : "Configurando...",
                    color: viewModel.transcriber.isModelLoaded ? .sapoGreen : .processing
                )
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sapoGreen.opacity(0.1))
        .cornerRadius(Constants.Sizes.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Sizes.cornerRadius)
                .stroke(Color.sapoGreen.opacity(0.3), lineWidth: 1)
        )
    }
    
    private var languagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Idiomas Soportados", systemImage: "globe")
                .font(.headline)
            
            HStack(spacing: 12) {
                LanguageChip(name: "Español", flag: "🇪🇸", isSelected: true)
                LanguageChip(name: "English", flag: "🇺🇸", isSelected: false)
                LanguageChip(name: "Auto", flag: "🌐", isSelected: false)
            }
            
            Text("El idioma se puede cambiar en Configuración")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
    
    private var whisperModelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Modelos Whisper", systemImage: "cpu")
                    .font(.headline)
                
                Spacer()
                
                Text("Próximamente")
                    .font(.caption)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue)
                    .cornerRadius(4)
            }
            
            Text("En una próxima versión podrás descargar modelos de Whisper para transcripción 100% local sin conexión a internet.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            // Lista de modelos (preview)
            VStack(spacing: 8) {
                ForEach(WhisperModel.allCases.prefix(3)) { model in
                    ModelPreviewRow(model: model)
                }
            }
            .opacity(0.6)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }
    
    // MARK: - Settings Tab

    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Micrófono
                microphoneCard

                // Idioma
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

    private var microphoneCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Micrófono", systemImage: "mic.fill")
                .font(.headline)

            Picker("Dispositivo de entrada", selection: $selectedMicrophone) {
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

    private var languageSelectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Idioma de Transcripción", systemImage: "globe")
                .font(.headline)

            HStack(spacing: 12) {
                LanguageButton(name: "Español", flag: "🇪🇸", languageCode: "es", selectedLanguage: $selectedLanguage)
                LanguageButton(name: "English", flag: "🇺🇸", languageCode: "en", selectedLanguage: $selectedLanguage)
                LanguageButton(name: "Auto", flag: "🌐", languageCode: "auto", selectedLanguage: $selectedLanguage)
            }

            Text("Selecciona el idioma en el que hablarás")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    @State private var isRecordingHotkey = false

    private var hotkeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Atajo de Teclado", systemImage: "keyboard")
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

            Text("Haz clic y presiona tu combinación de teclas (mínimo 2 teclas)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
    }

    private var behaviorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Comportamiento", systemImage: "gearshape")
                .font(.headline)

            Toggle(isOn: $autoPaste) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pegar automáticamente")
                    Text("El texto se pegará donde tengas el cursor")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            Toggle(isOn: $playSound) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sonidos de feedback")
                    Text("Reproduce sonidos al grabar y transcribir")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(Constants.Sizes.cornerRadius)
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
                        Text("SapoWhisper")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Speech-to-Text usando Apple Speech Recognition")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.top, 8)

                // Cómo funciona
                InfoSection(
                    icon: "questionmark.circle.fill",
                    title: "¿Cómo funciona?",
                    content: """
                    1. Presiona el atajo de teclado para iniciar
                    2. Habla claramente al micrófono
                    3. Presiona el atajo otra vez para detener
                    4. El texto se copia automáticamente
                    5. Con "Auto-pegar" activado, se pega donde tengas el cursor
                    """
                )

                // Privacidad
                InfoSection(
                    icon: "lock.shield.fill",
                    title: "Privacidad",
                    content: """
                    El audio se procesa usando el reconocimiento de voz de Apple. Tu voz no se almacena permanentemente.

                    En futuras versiones, podrás usar modelos de Whisper para transcripción 100% local.
                    """
                )

                // Permisos
                InfoSection(
                    icon: "hand.raised.fill",
                    title: "Permisos necesarios",
                    content: """
                    • Micrófono: Para capturar tu voz
                    • Reconocimiento de voz: Para transcribir el audio
                    • Accesibilidad: Para el atajo de teclado global
                    """
                )
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
            
            Button("Cerrar") {
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

struct StatusItem: View {
    let icon: String
    let title: String
    let status: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(status)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
    }
}

struct LanguageChip: View {
    let name: String
    let flag: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(flag)
            Text(name)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.sapoGreen.opacity(0.2) : Color(NSColor.controlBackgroundColor))
        .foregroundColor(isSelected ? .sapoGreen : .secondary)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Color.sapoGreen : Color.clear, lineWidth: 1)
        )
    }
}

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

struct ModelPreviewRow: View {
    let model: WhisperModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if model.isRecommended {
                        Text("★")
                            .foregroundColor(.yellow)
                    }
                }
                
                Text("\(model.fileSize) • \(model.speed)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Placeholder para botón de descarga
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(8)
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

#Preview {
    ModelDownloadView(viewModel: SapoWhisperViewModel())
}
