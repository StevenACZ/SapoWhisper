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
                // The launch preflight skipped itself while the permission was
                // missing; warm the route now that capture is allowed.
                AudioInputPreflightManager.shared.preflightSoon(reason: "mic-granted")
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
                    AudioInputPreflightManager.shared.preflightSoon(reason: "mic-granted")
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
        do {
            // AudioEngineGuard: AVFAudio asserts with uncatchable NSExceptions
            // mid route transition; a guarded throw means "cannot start input".
            let inputNode = try AudioEngineGuard.inputNode(of: engine, operation: "probe-input-node")
            let format = inputNode.outputFormat(forBus: 0)

            guard format.sampleRate > 0, format.channelCount > 0 else {
                return false
            }

            try AudioEngineGuard.installTap(
                on: inputNode, bufferSize: 64, format: format, operation: "probe-install-tap"
            ) { _, _ in }
            defer {
                // Best-effort teardown; the probe engine is discarded either way.
                try? AudioEngineGuard.run("probe-cleanup") {
                    inputNode.removeTap(onBus: 0)
                    if engine.isRunning {
                        engine.stop()
                    }
                    engine.reset()
                }
            }

            try AudioEngineGuard.prepareAndStart(engine, operation: "probe-engine-start")
            return engine.isRunning
        } catch {
            return false
        }
    }
}
