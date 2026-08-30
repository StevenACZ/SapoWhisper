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

/// Warms Core Audio route metadata after device changes so hotkey recording starts faster.
final class AudioInputPreflightManager {
    static let shared = AudioInputPreflightManager()

    private let deviceManager: AudioDeviceManager
    private let queue = DispatchQueue(label: "com.sapowhisper.audioPreflight", qos: .utility)
    private var cancellables = Set<AnyCancellable>()
    private var pendingWorkItem: DispatchWorkItem?
    private var hasStarted = false
    private var generation: UInt64 = 0
    /// Warm-up failures in a row (queue-confined); a fresh route change or a
    /// successful warm-up resets the budget.
    private var consecutiveWarmupFailures = 0
    private static let maxWarmupRetries = 2

    /// A8: set by the ViewModel; evaluated on the main thread before each run
    /// so the preflight engine never touches the device mid-capture.
    var isCaptureActive: (() -> Bool)?

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
        pendingWorkItem?.cancel()

        let delay = max(0, delayOverride ?? deviceManager.captureRouteSettleDelay() + 0.05)
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPreflight(reason: reason, generation: currentGeneration)
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func runPreflight(reason: String, generation: UInt64) {
        guard generation == self.generation else { return }

        // A fresh trigger (route change, wake, manual) gets a fresh retry
        // budget; only the retry path itself keeps consuming it.
        if reason != "warmup-retry" {
            consecutiveWarmupFailures = 0
        }

        // Starting the muted warm-up engine counts as capture for TCC, so on
        // a fresh install this background task would pop the system
        // microphone dialog out of nowhere. The guided permission flow owns
        // the first request; until then the route cache simply stays cold.
        guard MicrophonePermission.isGranted else {
            SapoLog.audioRoute.info(
                "Audio input preflight skipped reason=\(reason, privacy: .public) permission=microphone granted=false"
            )
            return
        }

        // A8: defer instead of fighting an active capture for the device; the
        // retry keeps the cache warm for the route in place after recording.
        let captureActive = DispatchQueue.main.sync { isCaptureActive?() ?? false }
        if captureActive {
            SapoLog.audioRoute.info(
                "Audio input preflight deferred reason=\(reason, privacy: .public) capture-active"
            )
            DispatchQueue.main.async { [weak self] in
                self?.schedulePreflight(reason: "\(reason)-deferred", delayOverride: 1.0)
            }
            return
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let selectedUID =
            UserDefaults.standard.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid

        deviceManager.refreshDevices()
        let deviceID = deviceManager.resolveSelectedInputDeviceID(for: selectedUID)
        switch audioInputPreflightDecision(selectedUID: selectedUID, resolvedDeviceID: deviceID) {
        case .waitForExplicitInput:
            SapoLog.audioRoute.info(
                "Audio input preflight skipped reason=\(reason, privacy: .public) selected-input-unavailable"
            )
            return
        case .skipExplicitAvailable:
            SapoLog.audioRoute.info(
                "Audio input preflight skipped reason=\(reason, privacy: .public) explicit-input-owned-by-capture"
            )
            return
        case .warmSystemDefault:
            break
        }

        guard AudioInputActivityGate.shared.beginPreflightIfIdle() else {
            SapoLog.audioRoute.info(
                "Audio input preflight deferred reason=\(reason, privacy: .public) input-busy"
            )
            DispatchQueue.main.async { [weak self] in
                self?.schedulePreflight(reason: "\(reason)-deferred", delayOverride: 1.0)
            }
            return
        }
        defer { AudioInputActivityGate.shared.endPreflight() }

        let currentSelectedUID =
            UserDefaults.standard.string(forKey: Constants.StorageKeys.selectedMicrophone)
            ?? AudioDevice.systemDefault.uid
        guard currentSelectedUID == AudioDevice.systemDefault.uid else {
            SapoLog.audioRoute.info(
                "Audio input preflight skipped reason=\(reason, privacy: .public) selection-changed"
            )
            return
        }
        deviceManager.refreshDevices()
        let currentDeviceID = deviceManager.resolveSelectedInputDeviceID(for: currentSelectedUID)
        let hardwareFormat = currentDeviceID.flatMap { queryInputFormat(deviceID: $0) }
        warmAVAudioInputNode(hardwareFormat: hardwareFormat)

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SapoLog.audioRoute.info(
            "Audio input preflight finished reason=\(reason, privacy: .public) elapsed=\(elapsedMs, privacy: .public)ms"
        )
    }

    /// Crash guard (three SIGABRT crash logs): every AVAudioEngine call here
    /// runs through AudioEngineGuard because AVFAudio asserts with NSException
    /// when the hardware format shifts mid-transition — exactly when this
    /// warm-up fires (AirPods connecting, headset swaps). A caught exception
    /// only means the route was still settling; retry once shortly after.
    private func warmAVAudioInputNode(hardwareFormat: AVAudioFormat?) {
        let engine = AVAudioEngine()
        defer {
            AudioEngineGuard.teardownAndRetire(
                engine,
                removeInputTap: true,
                operation: "preflight-teardown"
            )
        }
        do {
            let inputNode = try AudioEngineGuard.inputNode(of: engine, operation: "preflight-input-node")

            let tapFormat = hardwareFormat ?? inputNode.outputFormat(forBus: 0)
            guard tapFormat.sampleRate > 0, tapFormat.channelCount > 0 else { return }

            // L4: prepare()+reset() never touched the HAL, so the first recording
            // still paid full route setup. A brief muted start()/stop() forces the
            // I/O unit to open the device; the tap discards every buffer.
            try AudioEngineGuard.installTap(
                on: inputNode, bufferSize: 1024, format: tapFormat, operation: "preflight-install-tap"
            ) { _, _ in }
            inputNode.volume = 0
            try AudioEngineGuard.prepareAndStart(engine, operation: "preflight-engine-start")
            consecutiveWarmupFailures = 0
        } catch {
            let detail = LogSanitizer.errorDiagnostic(error, state: "input-preflight")
            SapoLog.audioRoute.warning(
                "Audio input preflight warm-up failed \(detail, privacy: .public)"
            )
            consecutiveWarmupFailures += 1
            if consecutiveWarmupFailures <= Self.maxWarmupRetries {
                DispatchQueue.main.async { [weak self] in
                    self?.schedulePreflight(reason: "warmup-retry", delayOverride: 1.2)
                }
            }
        }
    }

    private func queryInputFormat(deviceID: AudioDeviceID) -> AVAudioFormat? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)

        let status = AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &asbd)
        guard status == noErr else { return nil }
        return AVAudioFormat(streamDescription: &asbd)
    }
}
