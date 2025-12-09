//
//  ModelDownloadView.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI

/// Vista para gestionar la configuración de transcripción
struct ModelDownloadView: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection
            
            Divider()
            
            // Contenido - Sin TabView para evitar botones duplicados
            Group {
                if selectedTab == 0 {
                    modelsTab
                } else {
                    infoTab
                }
            }
            
            Divider()
            
            // Footer
            footerSection
        }
        .frame(width: 500, height: 520)
        .background(Color(NSColor.windowBackgroundColor))
        .toolbarBackground(Color(NSColor.windowBackgroundColor), for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .toolbar {
            // Picker en el centro de la barra de título
            ToolbarItem(placement: .principal) {
                Picker("", selection: $selectedTab) {
                    Text("Estado").tag(0)
                    Text("Información").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
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
            // Icono animado
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 80, height: 80)
                
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.sapoGreen, Color.sapoGreenDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
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
    
    // MARK: - Info Tab
    
    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Cómo funciona
                InfoSection(
                    icon: "questionmark.circle.fill",
                    title: "¿Cómo funciona?",
                    content: """
                    1. Presiona ⌥ + Space para iniciar la grabación
                    2. Habla claramente al micrófono
                    3. Presiona ⌥ + Space otra vez para detener
                    4. El texto se copia automáticamente al portapapeles
                    5. Si tienes "Auto-pegar" activado, el texto se pegará donde tengas el cursor
                    """
                )
                
                // Privacidad
                InfoSection(
                    icon: "lock.shield.fill",
                    title: "Privacidad",
                    content: """
                    El audio se procesa usando el reconocimiento de voz de Apple. Tu voz no se almacena ni se envía a terceros.
                    
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
                    • Accesibilidad (opcional): Para el atajo de teclado global
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
