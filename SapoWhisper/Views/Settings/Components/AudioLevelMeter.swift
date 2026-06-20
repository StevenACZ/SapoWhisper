//
//  AudioLevelMeter.swift
//  SapoWhisper
//
//

import SwiftUI

/// Componente visual de medidor de nivel de audio con barras animadas
struct AudioLevelMeter: View {
    @ObservedObject var monitor: AudioLevelMonitor

    /// Número de barras en el medidor
    let barCount: Int

    /// Altura del medidor
    let height: CGFloat

    init(monitor: AudioLevelMonitor = .shared, barCount: Int = 20, height: CGFloat = 20) {
        self.monitor = monitor
        self.barCount = barCount
        self.height = height
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    AudioBar(
                        isActive: isBarActive(index: index),
                        isPeak: isBarPeak(index: index),
                        color: barColor(index: index)
                    )
                }
            }
        }
        .frame(height: height)
    }

    /// Determina si una barra debe estar activa basado en el nivel actual
    private func isBarActive(index: Int) -> Bool {
        let threshold = Float(index) / Float(barCount)
        return monitor.audioLevel >= threshold
    }

    /// Determina si una barra es el pico actual
    private func isBarPeak(index: Int) -> Bool {
        let threshold = Float(index) / Float(barCount)
        let nextThreshold = Float(index + 1) / Float(barCount)
        return monitor.peakLevel >= threshold && monitor.peakLevel < nextThreshold
    }

    /// Color de la barra basado en su posición (verde -> amarillo -> rojo)
    private func barColor(index: Int) -> Color {
        let position = Float(index) / Float(barCount)

        if position < 0.6 {
            return .sapoGreen
        } else if position < 0.85 {
            return .yellow
        } else {
            return .red
        }
    }
}

/// Barra individual del medidor
struct AudioBar: View {
    let isActive: Bool
    let isPeak: Bool
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(barFill)
            .animation(.easeOut(duration: 0.05), value: isActive)
    }

    private var barFill: some ShapeStyle {
        if isActive {
            return AnyShapeStyle(color)
        } else if isPeak {
            return AnyShapeStyle(color.opacity(0.8))
        } else {
            return AnyShapeStyle(Color.secondary.opacity(0.2))
        }
    }
}

/// Vista completa del medidor con controles
struct AudioLevelMeterView: View {
    @StateObject private var monitor = AudioLevelMonitor.shared
    let deviceUID: String

    @State private var isEnabled = false
    @AppStorage(Constants.StorageKeys.audioGain) private var gain: Double = 1.0
    @AppStorage(Constants.StorageKeys.audioUploadQuality) private var audioUploadQuality =
        AudioUploadQuality.defaultValue.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Toggle + live status
            HStack {
                Toggle("settings.test_microphone".localized, isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(Constants.Colors.sapoGreen)

                Spacer()

                if isEnabled && monitor.isActive {
                    listeningBadge
                }
            }

            // Expanded mic test panel
            if isEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    // Error banner
                    if monitor.hasError, let error = monitor.errorMessage {
                        errorBanner(error)
                    }

                    // Level meter + percentage
                    HStack(spacing: 8) {
                        AudioLevelMeter(monitor: monitor)

                        Text("\(Int(monitor.audioLevel * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 35, alignment: .trailing)
                            .contentTransition(.numericText())
                    }

                    // Gain control
                    gainSlider

                    Divider()
                        .padding(.vertical, 2)

                    // Sample recording + playback
                    sampleRecordingSection
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .onChange(of: isEnabled) { _, newValue in
            if newValue {
                monitor.gain = Float(gain)
                monitor.restartMonitoring(deviceUID: deviceUID)
            } else {
                monitor.stopMonitoring()
            }
        }
        .onChange(of: deviceUID) { _, newUID in
            if isEnabled {
                monitor.restartMonitoring(deviceUID: newUID)
            }
        }
        .onChange(of: audioUploadQuality) { _, _ in
            _ = monitor.rebuildSentSample()
        }
        .onDisappear {
            monitor.stopMonitoring()
        }
    }

    // MARK: - Subviews

    private var listeningBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .shadow(color: .red.opacity(0.5), radius: 3)
            Text("settings.listening".localized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.red.opacity(0.08))
        .clipShape(Capsule())
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var gainSlider: some View {
        Slider(value: $gain, in: 1.0...40.0) {
            Text("settings.gain".localized)
        } minimumValueLabel: {
            Text("1x")
        } maximumValueLabel: {
            Text("\(String(format: "%.0f", gain))x")
        }
        .tint(Constants.Colors.sapoGreen)
        .controlSize(.small)
        .onChange(of: gain) { _, newValue in
            monitor.gain = Float(newValue)
        }
    }

    private var sampleRecordingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if monitor.isRecordingSample {
                    Button(action: { monitor.stopSampleRecording() }) {
                        Label("settings.stop_sample".localized, systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)

                    Spacer()

                    Text(formatSampleDuration(monitor.sampleRecordingDuration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Button(action: { monitor.startSampleRecording() }) {
                        Label("settings.record_sample".localized, systemImage: "mic.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!monitor.isActive)
                }
            }

            // Sample players
            if let rawURL = monitor.rawSampleURL,
                !monitor.isRecordingSample,
                let rawMeta = monitor.rawSampleMetadata
            {
                VStack(spacing: 4) {
                    AudioSamplePlayerView(
                        url: rawURL,
                        label: "settings.sample_original".localized,
                        metadata: rawMeta
                    )

                    if let sentURL = monitor.sentSampleURL,
                        let sentMeta = monitor.sentSampleMetadata
                    {
                        AudioSamplePlayerView(
                            url: sentURL,
                            label: "settings.sample_sent_quality".localized(currentAudioUploadQuality.displayName),
                            metadata: sentMeta
                        )
                    }
                }
            }
        }
    }

    private func formatSampleDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var currentAudioUploadQuality: AudioUploadQuality {
        AudioUploadQuality(rawValue: audioUploadQuality) ?? .defaultValue
    }
}

#Preview("Audio Level Meter") {
    VStack(spacing: 20) {
        AudioLevelMeterView(deviceUID: "default")
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(12)
    }
    .padding()
    .frame(width: 400)
}
