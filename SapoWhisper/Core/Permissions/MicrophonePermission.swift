//
//  MicrophonePermission.swift
//  SapoWhisper
//
//  Keeps microphone permission checks aligned with the audio recorder API.
//

import AVFoundation
import Foundation

/// Concurrency: nonisolated — checks run from capture queues too; the cached
/// flag sits behind `cacheLock`. UI-driven priming flows stay `@MainActor`.
nonisolated enum MicrophonePermission {
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedGranted = false

    static var isGranted: Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            noteAudioInputGranted()
            return true
        }

        if #available(macOS 14.0, *) {
            if AVAudioApplication.shared.recordPermission == .granted {
                noteAudioInputGranted()
                return true
            }
        }

        return isCachedGranted
    }

    static func noteAudioInputGranted() {
        cacheLock.lock()
        cachedGranted = true
        cacheLock.unlock()
    }

    @MainActor
    static func primeIfNeeded() async -> PermissionPrimingResult {
        if isGranted {
            return .granted
        }

        let captureStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if captureStatus == .notDetermined {
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }

            if granted || isGranted {
                noteAudioInputGranted()
                return .granted
            }
        }

        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                noteAudioInputGranted()
                return .granted
            case .denied:
                break
            case .undetermined:
                let granted = await AVAudioApplication.requestRecordPermission()
                if granted || isGranted {
                    noteAudioInputGranted()
                    return .granted
                }
            @unknown default:
                break
            }
        }

        if await refreshFromAudioInputProbeIfNeeded() {
            return .granted
        }

        return isGranted ? .granted : .needsSystemSettings
    }

    @MainActor
    static func refreshFromAudioInputProbeIfNeeded() async -> Bool {
        if isGranted {
            return true
        }

        guard shouldProbeAudioInput else {
            return false
        }

        let canStartInput = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: probeAudioInput())
            }
        }

        if canStartInput {
            noteAudioInputGranted()
        }

        return canStartInput
    }

    private static var isCachedGranted: Bool {
        cacheLock.lock()
        let granted = cachedGranted
        cacheLock.unlock()
        return granted
    }

    private static var shouldProbeAudioInput: Bool {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .notDetermined {
            return true
        }

        if #available(macOS 14.0, *) {
            return AVAudioApplication.shared.recordPermission != .undetermined
        }

        return false
    }

    private static func probeAudioInput() -> Bool {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0, format.channelCount > 0 else {
            return false
        }

        inputNode.installTap(onBus: 0, bufferSize: 64, format: format) { _, _ in }
        defer {
            inputNode.removeTap(onBus: 0)
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
        }

        do {
            engine.prepare()
            try engine.start()
            return engine.isRunning
        } catch {
            return false
        }
    }
}
