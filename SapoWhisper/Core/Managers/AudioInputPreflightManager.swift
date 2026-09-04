//
//  AudioInputPreflightManager.swift
//  SapoWhisper
//

import AVFoundation
import Combine
import CoreAudio
import Foundation
import os

nonisolated enum AudioInputPreflightDecision: Equatable {
    case warmSystemDefault
    case skipExplicitAvailable
    case waitForExplicitInput
}

nonisolated func audioInputPreflightDecision(
    selectedUID: String,
    resolvedDeviceID: AudioDeviceID?
) -> AudioInputPreflightDecision {
    guard selectedUID != AudioDevice.systemDefault.uid else { return .warmSystemDefault }
    return resolvedDeviceID == nil ? .waitForExplicitInput : .skipExplicitAvailable
}

@MainActor
final class AudioInputPreflightManager {
    static let shared = AudioInputPreflightManager()

    private let deviceManager: AudioDeviceManager
    private var cancellables = Set<AnyCancellable>()
    private var pendingTask: Task<Void, Never>?
    private var hasStarted = false
    private var generation: UInt64 = 0
    private var consecutiveWarmupFailures = 0
    private static let maxWarmupRetries = 2

    var isCaptureActive: (@MainActor () -> Bool)?

    private init(deviceManager: AudioDeviceManager = .shared) {
        self.deviceManager = deviceManager
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        deviceManager.routeChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.schedulePreflight(reason: "route-change")
            }
            .store(in: &cancellables)

        schedulePreflight(reason: "launch", delayOverride: 0.4)
    }

    func preflightSoon(reason: String = "manual") {
        schedulePreflight(reason: reason, delayOverride: 0.05)
    }

    private func schedulePreflight(reason: String, delayOverride: TimeInterval? = nil) {
        generation &+= 1
        let currentGeneration = generation
        pendingTask?.cancel()
        if reason != "warmup-retry" {
            consecutiveWarmupFailures = 0
        }

        let delay = max(0, delayOverride ?? deviceManager.captureRouteSettleDelay() + 0.05)
        pendingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.runPreflight(reason: reason, generation: currentGeneration)
        }
    }

    private func runPreflight(reason: String, generation: UInt64) async {
        guard generation == self.generation, !Task.isCancelled else { return }
        guard MicrophonePermission.isGranted else { return }
        let snapshot = AudioInputPreflightWorker.Snapshot(
            selectedUID: AppPreferences.defaults.string(forKey: Constants.StorageKeys.selectedMicrophone)
                ?? AudioDevice.systemDefault.uid,
            routeEpoch: AudioInputSetupQuarantine.shared.currentEpoch
        )
        guard snapshot.selectedUID == AudioDevice.systemDefault.uid else { return }

        if isCaptureActive?() == true {
            schedulePreflight(reason: "capture-active", delayOverride: 1.0)
            return
        }

        let result: AudioInputPreflightWorker.Outcome
        do {
            result = try await AudioInputPreflightWorker.run(snapshot: snapshot, deviceManager: deviceManager)
        } catch is CancellationError {
            return
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            let detail = LogSanitizer.errorDiagnostic(error, state: "input-preflight")
            SapoLog.audioRoute.warning("Audio input preflight failed \(detail, privacy: .public)")
            consecutiveWarmupFailures += 1
            if consecutiveWarmupFailures <= Self.maxWarmupRetries {
                schedulePreflight(reason: "warmup-retry", delayOverride: 1.2)
            }
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        switch result {
        case .warmed:
            consecutiveWarmupFailures = 0
            SapoLog.audioRoute.info("Audio input preflight finished reason=\(reason, privacy: .public)")
        case .inputBusy:
            schedulePreflight(reason: "input-busy", delayOverride: 1.0)
        case .skipped:
            break
        }
    }
}

nonisolated private enum AudioInputPreflightWorker {
    struct Snapshot: Sendable {
        let selectedUID: String
        let routeEpoch: UInt64
    }

    enum Outcome: Sendable {
        case warmed
        case inputBusy
        case skipped
    }

    static func run(snapshot: Snapshot, deviceManager: AudioDeviceManager) async throws -> Outcome {
        let request = AudioDeadlineRequest<Outcome>()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let attempt = AudioDeadlineAttempt<Outcome>(
                    timeout: 5,
                    operation: "input-preflight",
                    worker: DispatchQueue(label: "com.sapowhisper.audioPreflight", qos: .utility),
                    work: {
                        try prepare(snapshot: snapshot, deviceManager: deviceManager) {
                            cancelled.withLock { $0 }
                        }
                    },
                    cleanup: { _ in },
                    onQuarantine: { _ in
                        cancelled.withLock { $0 = true }
                        AudioInputSetupQuarantine.shared.quarantine(epoch: snapshot.routeEpoch)
                    },
                    completion: { continuation.resume(with: $0) }
                )
                request.install(attempt)
                attempt.start()
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
            request.cancel()
        }
    }

    private static func prepare(
        snapshot: Snapshot,
        deviceManager: AudioDeviceManager,
        isCancelled: @Sendable () -> Bool
    ) throws -> Outcome {
        guard !isCancelled(), snapshot.selectedUID == AudioDevice.systemDefault.uid,
            AudioInputSetupQuarantine.shared.currentEpoch == snapshot.routeEpoch,
            AudioInputSetupQuarantine.shared.canAttempt(epoch: snapshot.routeEpoch),
            MicrophonePermission.isGranted
        else { return .skipped }

        guard AudioInputActivityGate.shared.beginPreflightIfIdle() else { return .inputBusy }
        // A timed-out HAL call still owns the microphone until physical teardown finishes.
        defer { AudioInputActivityGate.shared.endPreflight() }

        let currentSelectedUID =
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid
        deviceManager.refreshDevices()
        let deviceID = deviceManager.resolveSelectedInputDeviceID(for: currentSelectedUID)
        guard
            audioInputPreflightDecision(selectedUID: currentSelectedUID, resolvedDeviceID: deviceID)
                == .warmSystemDefault,
            AudioInputSetupQuarantine.shared.currentEpoch == snapshot.routeEpoch
        else { return .skipped }
        let hardwareFormat = deviceID.flatMap { queryInputFormat(deviceID: $0) }
        let latestSelectedUID =
            AppPreferences.defaults.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid
        guard !isCancelled(), latestSelectedUID == snapshot.selectedUID,
            AudioInputSetupQuarantine.shared.currentEpoch == snapshot.routeEpoch
        else { return .skipped }
        return try warmAVAudioInputNode(hardwareFormat: hardwareFormat) {
            isCancelled()
                || AppPreferences.defaults.string(forKey: Constants.StorageKeys.selectedMicrophone)
                    .map { $0 != snapshot.selectedUID } == true
                || AudioInputSetupQuarantine.shared.currentEpoch != snapshot.routeEpoch
        }
    }

    private static func warmAVAudioInputNode(
        hardwareFormat: AVAudioFormat?,
        isCancelled: @Sendable () -> Bool
    ) throws -> Outcome {
        let engine = AVAudioEngine()
        var tapInstalled = false
        defer {
            AudioEngineGuard.teardownAndRetire(
                engine,
                removeInputTap: tapInstalled,
                operation: "preflight-teardown"
            )
        }
        let inputNode = try AudioEngineGuard.inputNode(of: engine, operation: "preflight-input-node")
        let tapFormat = try AudioEngineGuard.run("preflight-input-format") {
            hardwareFormat ?? inputNode.outputFormat(forBus: 0)
        }
        guard !isCancelled(), tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { return .skipped }
        try AudioEngineGuard.installTap(
            on: inputNode, bufferSize: 1024, format: tapFormat, operation: "preflight-install-tap"
        ) { _, _ in }
        tapInstalled = true
        try AudioEngineGuard.run("preflight-mute") { inputNode.volume = 0 }
        try AudioEngineGuard.prepareAndStart(engine, operation: "preflight-engine-start")
        return .warmed
    }

    private static func queryInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let result = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard result == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
