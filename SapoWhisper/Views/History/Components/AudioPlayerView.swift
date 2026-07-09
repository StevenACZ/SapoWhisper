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
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
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

/// Inline audio player card: round play button, scrubbable progress bar,
/// and current/total times under the bar.
struct AudioPlayerView: View {
    let audioPath: String

    @ObservedObject private var controller = HistoryAudioPlayerController.shared

    /// Seconds moved per VoiceOver adjustment or arrow-key press.
    private static let seekStep: TimeInterval = 5

    var body: some View {
        HStack(spacing: 14) {
            Button(action: { controller.togglePlayback(path: audioPath) }) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.sapoGreen))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help((controller.isPlaying ? "history.pause" : "history.play").localized)
            .accessibilityLabel((controller.isPlaying ? "history.pause" : "history.play").localized)

            VStack(spacing: 5) {
                // Progress bar with click + drag scrubbing
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 5)

                        Capsule()
                            .fill(Color.sapoGreen)
                            .frame(
                                width: controller.duration > 0
                                    ? geo.size.width * (controller.currentTime / controller.duration) : 0,
                                height: 5
                            )
                            // Bridge the 0.1 s timer ticks so the fill glides
                            // instead of stepping.
                            .animation(Constants.Animation.progress, value: controller.currentTime)
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                controller.seek(path: audioPath, to: value.location.x / geo.size.width)
                            }
                    )
                }
                .frame(height: 14)
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: seek(by: -Self.seekStep)
                    case .right: seek(by: Self.seekStep)
                    default: break
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("history.audio_scrubber".localized)
                .accessibilityValue(
                    "history.audio_position".localized(
                        formatTime(controller.currentTime), formatTime(controller.duration)
                    )
                )
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: seek(by: Self.seekStep)
                    case .decrement: seek(by: -Self.seekStep)
                    @unknown default: break
                    }
                }

                HStack {
                    Text(formatTime(controller.currentTime))
                    Spacer()
                    Text(formatTime(controller.duration))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        )
        .onAppear { controller.prepare(path: audioPath) }
        .onChange(of: audioPath) { _, newPath in
            controller.prepare(path: newPath)
        }
        .onDisappear { controller.stopIfLoaded(path: audioPath) }
    }

    private func seek(by seconds: TimeInterval) {
        guard controller.duration > 0 else { return }
        controller.seek(path: audioPath, to: (controller.currentTime + seconds) / controller.duration)
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
