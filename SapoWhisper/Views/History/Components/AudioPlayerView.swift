//
//  AudioPlayerView.swift
//  SapoWhisper
//

import AVFoundation
import Combine
import SwiftUI
import os

/// R3/H9: one shared AVAudioPlayer for the whole history detail pane. The
/// detail view re-renders per entry; sharing the player guarantees a single
/// live instance, stops playback on entry switch, and the progress timer only
/// runs while audio is actually playing.
@MainActor
final class HistoryAudioPlayerController: ObservableObject {
    static let shared = HistoryAudioPlayerController()

    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var loadedPath: String?
    private var timer: Timer?

    private init() {}

    func prepare(path: String) {
        guard path != loadedPath else { return }
        load(path: path)
    }

    func togglePlayback(path: String) {
        if path != loadedPath {
            load(path: path)
        }
        guard let player else { return }

        if isPlaying {
            player.pause()
            stopProgressTimer()
            isPlaying = false
        } else {
            player.play()
            startProgressTimer()
            isPlaying = true
        }
    }

    func seek(path: String, to fraction: Double) {
        guard path == loadedPath, let player else { return }
        let clamped = max(0, min(1, fraction))
        let time = duration * clamped
        player.currentTime = time
        currentTime = time
    }

    /// Stop when the pane showing this path goes away; a stale disappear from
    /// a previous entry must not kill the entry loaded after it.
    func stopIfLoaded(path: String) {
        guard path == loadedPath else { return }
        stop()
    }

    private func load(path: String) {
        stop()
        loadedPath = path
        currentTime = 0
        duration = 0

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            SapoLog.settings.warning(
                "History AudioPlayer load failed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func stop() {
        stopProgressTimer()
        player?.stop()
        player = nil
        loadedPath = nil
        isPlaying = false
    }

    private func startProgressTimer() {
        stopProgressTimer()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tickProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopProgressTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tickProgress() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            currentTime = 0
            stopProgressTimer()
        }
    }
}

/// Mini inline audio player for playback of saved transcription audio
struct AudioPlayerView: View {
    let audioPath: String

    @ObservedObject private var controller = HistoryAudioPlayerController.shared

    var body: some View {
        HStack(spacing: 10) {
            // Play/Pause button
            Button(action: { controller.togglePlayback(path: audioPath) }) {
                Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(controller.isPlaying ? Color.sapoGreen : Color.secondary)
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
                        .frame(
                            width: controller.duration > 0
                                ? geo.size.width * (controller.currentTime / controller.duration) : 0,
                            height: 4
                        )
                }
                .frame(height: geo.size.height)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    controller.seek(path: audioPath, to: location.x / geo.size.width)
                }
            }
            .frame(height: 20)

            // Time display
            Text("\(formatTime(controller.currentTime)) / \(formatTime(controller.duration))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(10)
        .background(.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onAppear { controller.prepare(path: audioPath) }
        .onChange(of: audioPath) { _, newPath in
            controller.prepare(path: newPath)
        }
        .onDisappear { controller.stopIfLoaded(path: audioPath) }
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
