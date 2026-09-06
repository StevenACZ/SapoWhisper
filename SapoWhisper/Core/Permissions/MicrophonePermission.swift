//
//  MicrophonePermission.swift
//  SapoWhisper
//
//  Keeps microphone permission checks aligned with the audio recorder API.
//

import AVFoundation
import Foundation

nonisolated func microphonePermissionShouldProbeAudioInput(selectedUID: String) -> Bool {
    selectedUID == AudioDevice.systemDefault.uid
}

nonisolated func microphonePermissionShouldInvalidateCache(
    capturePermissionDenied: Bool,
    recordPermissionDenied: Bool
) -> Bool {
    capturePermissionDenied && recordPermissionDenied
}

/// Concurrency: nonisolated — checks run from capture queues too; the cached
/// flag sits behind `cacheLock`. UI-driven priming flows stay `@MainActor`.
nonisolated enum MicrophonePermission {
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedGranted = false

    static var isGranted: Bool {
        let captureStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if captureStatus == .authorized {
            noteAudioInputGranted()
            return true
        }

        if #available(macOS 14.0, *) {
            let recordPermission = AVAudioApplication.shared.recordPermission
            if recordPermission == .granted {
                noteAudioInputGranted()
                return true
            }
            if microphonePermissionShouldInvalidateCache(
                capturePermissionDenied: captureStatus == .denied || captureStatus == .restricted,
                recordPermissionDenied: recordPermission == .denied
            ) {
                setCachedGranted(false)
                return false
            }
        }

        return isCachedGranted
    }

    static func noteAudioInputGranted() {
        setCachedGranted(true)
    }

    private static func setCachedGranted(_ granted: Bool) {
        cacheLock.lock()
        cachedGranted = granted
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
        let selectedUID =
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid
        guard microphonePermissionShouldProbeAudioInput(selectedUID: selectedUID) else {
            return false
        }
        let canStartInput = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard AudioInputActivityGate.shared.beginPreflightIfIdle() else {
                    continuation.resume(returning: false)
                    return
                }
                let result = probeAudioInput()
                AudioInputActivityGate.shared.endPreflight()
                continuation.resume(returning: result)
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
        defer {
            AudioEngineGuard.teardownAndRetire(
                engine,
                removeInputTap: true,
                operation: "probe-cleanup"
            )
        }
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
            try AudioEngineGuard.prepareAndStart(engine, operation: "probe-engine-start")
            return engine.isRunning
        } catch {
            return false
        }
    }
}
