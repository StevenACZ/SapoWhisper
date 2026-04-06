//
//  AudioPlayerView.swift
//  SapoWhisper
//

import SwiftUI
import AVFoundation

/// Mini inline audio player for playback of saved transcription audio
struct AudioPlayerView: View {
    let audioPath: String

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timer: Timer?

    var body: some View {
        HStack(spacing: 10) {
            // Play/Pause button
            Button(action: togglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.sapoGreen : Color.secondary)
            }
            .buttonStyle(.plain)

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.sapoGreen)
                        .frame(width: duration > 0 ? geo.size.width * (currentTime / duration) : 0, height: 4)
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    seek(to: location.x / geo.size.width)
                }
            }
            .frame(height: 20)

            // Time display
            Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear(perform: loadAudio)
        .onDisappear(perform: cleanup)
    }

    private func loadAudio() {
        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            duration = player?.duration ?? 0
        } catch {
            print("AudioPlayerView: Failed to load audio: \(error)")
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
        let clamped = max(0, min(1, fraction))
        let time = duration * clamped
        player?.currentTime = time
        currentTime = time
    }

    private func cleanup() {
        timer?.invalidate()
        player?.stop()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview("Audio Player") {
    AudioPlayerView(audioPath: "/tmp/test.wav")
        .frame(width: 350)
        .padding()
}
