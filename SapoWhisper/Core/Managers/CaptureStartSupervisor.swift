//
//  CaptureStartSupervisor.swift
//  SapoWhisper
//

import Foundation
import os

/// The slice of `AudioCaptureEngine` the batch start/recovery loop drives;
/// tests substitute a fake recorder.
nonisolated protocol BatchCaptureStarting: AnyObject, Sendable {
    var selectedDeviceUID: String { get set }
    func prepareInputDeviceForRecording() -> TimeInterval
    func startRecording(targetEngine: TranscriptionEngine?, onPCMChunk: AudioCaptureEngine.PCMChunkHandler?) async throws
    func waitForFirstInputBuffer(timeout: TimeInterval) async -> Bool
    func currentCaptureDiagnostics() -> RecordingCaptureDiagnostics
    func discardRecording()
}

extension AudioCaptureEngine: BatchCaptureStarting {}

/// Start-with-recovery for the batch recorder: route-settle delays, the
/// first-input-buffer gate, transient-failure classification, and a retry
/// budget that widens on Bluetooth inputs. Makes no AVAudioEngine calls
/// itself — everything goes through `BatchCaptureStarting`.
@MainActor
final class CaptureStartSupervisor {

    private enum Timing {
        static let firstInputBufferTimeout: TimeInterval = 0.8
        static let startRetryBudget: TimeInterval = 1.0
        /// Bluetooth inputs renegotiate the link when the mic opens (AirPods
        /// switch A2DP→HFP, 1–3 s of dead air). The default timeouts declared the
        /// capture failed while the handshake was still in flight, so BT inputs
        /// get a wider first-buffer window and retry budget.
        static let bluetoothFirstInputBufferTimeout: TimeInterval = 2.5
        static let bluetoothStartRetryBudget: TimeInterval = 5.0
        static let startRetryBackoffs: [TimeInterval] = [0.15, 0.30]
    }

    private let recorder: any BatchCaptureStarting
    private let transport: (String) -> AudioDeviceTransport
    private let routeSettleDelay: () -> TimeInterval
    private let sleep: (TimeInterval) async -> Void

    init(
        recorder: any BatchCaptureStarting,
        transport: @escaping (String) -> AudioDeviceTransport = {
            AudioDeviceManager.shared.effectiveInputTransport(forSelectedUID: $0)
        },
        routeSettleDelay: @escaping () -> TimeInterval = { AudioDeviceManager.shared.captureRouteSettleDelay() },
        sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) {
        self.recorder = recorder
        self.transport = transport
        self.routeSettleDelay = routeSettleDelay
        self.sleep = sleep
    }

    func start(microphone: String, targetEngine: TranscriptionEngine) async throws {
        let transport = self.transport(microphone)
        let retryBudget = transport == .bluetooth ? Timing.bluetoothStartRetryBudget : Timing.startRetryBudget
        if transport == .bluetooth {
            SapoLog.recording.info("Capture start on Bluetooth input, using extended timeouts")
        }
        let deadline = CFAbsoluteTimeGetCurrent() + retryBudget
        var lastFailure: Error = RecordingError.noInputAfterDeviceSwitch

        for attempt in 1...3 {
            guard !Task.isCancelled else { throw CancellationError() }

            do {
                let didStart = try await attemptStart(
                    microphone: microphone,
                    targetEngine: targetEngine,
                    attempt: attempt,
                    minimumDelay: attempt == 1 ? 0 : Timing.startRetryBackoffs[attempt - 2],
                    firstInputTimeout: transport == .bluetooth
                        ? Timing.bluetoothFirstInputBufferTimeout : Timing.firstInputBufferTimeout
                )
                if didStart {
                    if attempt > 1 {
                        SapoLog.recording.info("Capture recovered on retry after route transition")
                    }
                    return
                }
                lastFailure = RecordingError.noInputAfterDeviceSwitch
            } catch {
                if error is CancellationError {
                    throw error
                }
                lastFailure = error
            }

            recorder.discardRecording()

            guard attempt < 3 else { break }

            let routeTransitionActive = routeSettleDelay() > 0
            let classification = classifyRecordingStartFailure(lastFailure, routeTransitionActive: routeTransitionActive)
            guard classification.isTransient else {
                throw lastFailure
            }

            let remainingBudget = deadline - CFAbsoluteTimeGetCurrent()
            guard remainingBudget > 0 else { break }

            let retryDelay = min(
                remainingBudget,
                max(Timing.startRetryBackoffs[attempt - 1], routeSettleDelay())
            )

            SapoLog.recording.warning(
                "Capture transient start failure reason=\(classification.reason, privacy: .public) attempt=\(attempt + 1, privacy: .public)/3 retryAfterMs=\(Int(retryDelay * 1000), privacy: .public)"
            )
            await sleep(retryDelay)
        }

        throw lastFailure
    }

    private func attemptStart(
        microphone: String,
        targetEngine: TranscriptionEngine,
        attempt: Int,
        minimumDelay: TimeInterval,
        firstInputTimeout: TimeInterval
    ) async throws -> Bool {
        recorder.selectedDeviceUID = microphone
        let settleDelay = max(minimumDelay, recorder.prepareInputDeviceForRecording())
        if settleDelay > 0 {
            let settleMs = Int(settleDelay * 1000)
            SapoLog.recording.info("Delaying recorder start for route settle \(settleMs, privacy: .public)ms")
            await sleep(settleDelay)
        }

        guard !Task.isCancelled else { return false }

        try await recorder.startRecording(targetEngine: targetEngine, onPCMChunk: nil)
        let receivedInput = await recorder.waitForFirstInputBuffer(timeout: firstInputTimeout)
        if receivedInput {
            return true
        }

        let diagnostics = recorder.currentCaptureDiagnostics()
        let inputDescription = diagnostics.selectedDeviceUID == "default" ? "system-default" : diagnostics.selectedDeviceUID
        SapoLog.recording.warning(
            "Capture no-input attempt=\(attempt, privacy: .public) timeoutMs=\(Int(firstInputTimeout * 1000), privacy: .public) bytes=\(diagnostics.fileSizeBytes, privacy: .public) input=\(inputDescription, privacy: .public)"
        )
        return false
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
            .permissionDenied:
            return false
        }
    }
}
