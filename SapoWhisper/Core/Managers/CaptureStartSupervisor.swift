import Foundation
import os

nonisolated protocol CaptureStarting: AnyObject, Sendable {
    var selectedDeviceUID: String { get set }
    func prepareInputDeviceForRecording() -> TimeInterval
    func startRecording(targetEngine: TranscriptionEngine?, onPCMChunk: AudioCaptureEngine.PCMChunkHandler?) async throws
    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool
    func currentCaptureDiagnostics() -> RecordingCaptureDiagnostics
    func discardRecording()
}

extension AudioCaptureEngine: CaptureStarting {}

@MainActor
final class CaptureStartSupervisor {
    private let recorder: any CaptureStarting
    private let mode: AudioCaptureEngine.Mode
    private let transport: (String) -> AudioDeviceTransport
    private let routeSettleDelay: () -> TimeInterval
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void

    init(
        recorder: any CaptureStarting,
        mode: AudioCaptureEngine.Mode = .batch,
        transport: @escaping (String) -> AudioDeviceTransport = {
            AudioDeviceManager.shared.effectiveInputTransport(forSelectedUID: $0)
        },
        routeSettleDelay: @escaping () -> TimeInterval = { AudioDeviceManager.shared.captureRouteSettleDelay() },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.recorder = recorder
        self.mode = mode
        self.transport = transport
        self.routeSettleDelay = routeSettleDelay
        self.now = now
        self.sleep = sleep
    }

    func start(
        microphone: String,
        targetEngine: TranscriptionEngine? = nil,
        onPCMChunk: AudioCaptureEngine.PCMChunkHandler? = nil
    ) async throws {
        let bluetooth = transport(microphone) == .bluetooth
        let firstInputTimeout: TimeInterval = bluetooth ? 2.5 : (mode == .streaming ? 1.2 : 0.8)
        let retryBudget: TimeInterval = bluetooth ? 5 : (mode == .streaming ? 3 : 1)
        let backoffs: [TimeInterval] = mode == .streaming ? [0.25, 0.60] : [0.15, 0.30]
        let startedAt = now()
        var recoveryDeadline: TimeInterval?
        var lastFailure: Error = RecordingError.noInputAfterDeviceSwitch

        for attempt in 1...3 {
            try Task.checkCancellation()
            recorder.selectedDeviceUID = microphone
            let routeDelay = max(recorder.prepareInputDeviceForRecording(), routeSettleDelay())
            let delay = max(routeDelay, attempt == 1 ? 0 : backoffs[attempt - 2])
            if let recoveryDeadline, now() + delay >= recoveryDeadline { break }
            if delay > 0 {
                await sleep(delay)
            }
            try Task.checkCancellation()
            if let recoveryDeadline, now() >= recoveryDeadline { break }

            do {
                try await recorder.startRecording(targetEngine: targetEngine, onPCMChunk: onPCMChunk)
                let receivedInput = await recorder.waitForFirstInputBuffer(timeout: firstInputTimeout)
                try Task.checkCancellation()
                if receivedInput {
                    if attempt > 1 {
                        SapoLog.recording.notice(
                            "Capture start recovered mode=\(self.mode.opPrefix, privacy: .public) attempt=\(attempt, privacy: .public) elapsedMs=\(Int((self.now() - startedAt) * 1000), privacy: .public)"
                        )
                    }
                    return
                }
                throw RecordingError.noInputAfterDeviceSwitch
            } catch {
                recorder.discardRecording()
                if error is CancellationError { throw error }
                lastFailure = error
            }

            let classification = classifyRecordingStartFailure(
                lastFailure,
                routeTransitionActive: routeDelay > 0 || routeSettleDelay() > 0
            )
            guard classification.isTransient else { throw lastFailure }
            guard attempt < 3 else { break }
            // The initial HAL setup has its own deadline; it must not consume the recovery window.
            if recoveryDeadline == nil { recoveryDeadline = now() + retryBudget }
            SapoLog.recording.notice(
                "Capture start retry mode=\(self.mode.opPrefix, privacy: .public) reason=\(classification.reason, privacy: .public) attempt=\(attempt + 1, privacy: .public)/3 elapsedMs=\(Int((self.now() - startedAt) * 1000), privacy: .public)"
            )
        }

        throw lastFailure
    }

    static func isRecoverableInputStartError(_ error: Error) -> Bool {
        guard let recordingError = error as? RecordingError else { return false }

        switch recordingError {
        case .noInputAfterDeviceSwitch, .invalidFormat:
            return true
        case .engineCreationFailed,
            .fileCreationFailed,
            .converterCreationFailed,
            .inputDeviceUnavailable,
            .deviceSelectionFailed,
            .permissionDenied,
            .inputSetupTimedOut:
            return false
        }
    }
}
