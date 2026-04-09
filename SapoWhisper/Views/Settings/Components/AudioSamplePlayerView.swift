//
//  AudioSamplePlayerView.swift
//  SapoWhisper
//

import SwiftUI
import AVFoundation

/// Compact inline player with metadata for mic test sample playback
struct AudioSamplePlayerView: View {
    let url: URL
    let label: String
    let metadata: SampleMetadata

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(isPlaying ? Color.sapoGreen : .secondary)
                }
                .buttonStyle(.plain)

                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .frame(width: 90, alignment: .leading)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 3)

                        Capsule()
                            .fill(Color.sapoGreen)
                            .frame(width: duration > 0 ? geo.size.width * (currentTime / duration) : 0, height: 3)
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        seek(to: location.x / geo.size.width)
                    }
                }
                .frame(height: 14)

                Text(formatTime(duration))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(minWidth: 28, alignment: .trailing)
            }

            // Metadata line
            Text("\(String(format: "%.0f", metadata.sampleRate))Hz  \(metadata.format)  \(metadata.formattedSize)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.leading, 22)
        }
        .padding(.vertical, 3)
        .onAppear(perform: loadAudio)
        .onDisappear(perform: cleanup)
        .onChange(of: url) { _, _ in loadAudio() }
    }

    private func loadAudio() {
        cleanup()
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            print("AudioSamplePlayerView: Failed to load: \(error)")
        }
    }

    private func togglePlayback() {
        guard let player else { return }

        if isPlaying {
            player.pause()
            timer?.invalidate()
        } else {
            player.play()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                currentTime = player.currentTime
                if !player.isPlaying {
                    isPlaying = false
                    timer?.invalidate()
                    currentTime = 0
                }
            }
        }
        isPlaying.toggle()
    }

    private func seek(to fraction: Double) {
        let time = duration * max(0, min(1, fraction))
        player?.currentTime = time
        currentTime = time
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
