//
//  AudioEngineGuard.swift
//  SapoWhisper
//

// AVFAudio tap blocks predate Sendable annotations (same discipline as the
// capture files that pass them through this guard).
@preconcurrency import AVFAudio
import Foundation
import os

/// An Objective-C exception raised by AVFAudio, caught and rethrown as a
/// recoverable Swift error instead of killing the process.
///
/// AVFAudio asserts its preconditions (tap format vs. hardware format, HAL
/// device state) with NSException. During audio route transitions — AirPods
/// finishing their Bluetooth handshake, a headset plugging in — the hardware
/// format can change or momentarily read as invalid between the query and the
/// engine call, and the resulting throw is uncatchable from Swift: the app
/// died with SIGABRT (three crash logs, all in `installTap` during device
/// changes). Start paths treat this error as transient and retry after the
/// route settles.
nonisolated struct AudioEngineObjCException: LocalizedError {
    let operation: String
    let name: String
    let reason: String

    var errorDescription: String? {
        "error.input_not_ready".localized
    }

    var diagnosticDescription: String {
        "\(operation) raised \(name): \(reason)"
    }
}

/// Wraps the AVAudioEngine calls that validate with NSException so route-change
/// races surface as throwable errors. Every engine touched through a failed
/// call must be discarded and rebuilt — the exception may leave it half-configured.
nonisolated enum AudioEngineGuard {

    static func run<T>(_ operation: String, _ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let exception = SapoWhisperCatchObjCException {
            result = Result(catching: body)
        }
        if let exception {
            let name = exception.name.rawValue
            let reason = exception.reason ?? "unknown"
            SapoLog.recording.error(
                "AVFAudio ObjC exception caught operation=\(operation, privacy: .public) name=\(name, privacy: .public) reason=\(reason, privacy: .public)"
            )
            throw AudioEngineObjCException(operation: operation, name: name, reason: reason)
        }
        guard let result else {
            throw AudioEngineObjCException(operation: operation, name: "MissingResult", reason: "body did not run")
        }
        return try result.get()
    }

    /// First access materializes the I/O unit and can throw when no input
    /// device is available mid-transition.
    static func inputNode(of engine: AVAudioEngine, operation: String) throws -> AVAudioInputNode {
        try run(operation) { engine.inputNode }
    }

    /// `installTap` throws NSException when the requested format disagrees
    /// with what the (possibly still-renegotiating) hardware reports.
    static func installTap(
        on node: AVAudioNode,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        operation: String,
        block: @escaping AVAudioNodeTapBlock
    ) throws {
        try run(operation) {
            node.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
        }
    }

    /// prepare()+start() both touch the HAL and can assert during route churn.
    static func prepareAndStart(_ engine: AVAudioEngine, operation: String) throws {
        try run(operation) {
            engine.prepare()
            try engine.start()
        }
    }

    static func teardownAndRetire(
        _ engine: AVAudioEngine,
        removeInputTap: Bool,
        operation: String
    ) {
        if removeInputTap {
            try? run("\(operation)-remove-tap") {
                engine.inputNode.removeTap(onBus: 0)
            }
        }
        try? run("\(operation)-stop") { engine.stop() }
        try? run("\(operation)-reset") { engine.reset() }
        AudioEngineRetirementPool.shared.retire(engine)
    }
}

nonisolated final class AudioEngineRetirementPool: @unchecked Sendable {
    private final class EngineBox: @unchecked Sendable {
        let engine: AVAudioEngine

        init(_ engine: AVAudioEngine) {
            self.engine = engine
        }
    }

    static let shared = AudioEngineRetirementPool()
    static let quietPeriod: TimeInterval = 3.0

    private let queue = DispatchQueue(label: "com.sapowhisper.audioEngine.retirement", qos: .utility)
    private var engines: [EngineBox] = []
    private var latestRetirement: CFAbsoluteTime = 0
    private var generation: UInt64 = 0
    private var systemSleeping = false

    func retire(_ engine: AVAudioEngine) {
        let engineBox = EngineBox(engine)
        queue.async { [self] in
            engines.append(engineBox)
            latestRetirement = CFAbsoluteTimeGetCurrent()
            generation &+= 1
            scheduleDrain(generation: generation, after: Self.quietPeriod)
        }
    }

    func noteSystemWillSleep() {
        queue.sync { [self] in
            systemSleeping = true
            generation &+= 1
        }
    }

    func noteSystemWake() {
        queue.async { [self] in
            systemSleeping = false
            guard !engines.isEmpty else { return }
            latestRetirement = CFAbsoluteTimeGetCurrent()
            generation &+= 1
            scheduleDrain(generation: generation, after: Self.quietPeriod)
        }
    }

    static func releaseDelay(
        elapsedSinceRetirement: TimeInterval,
        routeSettleDelay: TimeInterval
    ) -> TimeInterval {
        max(0, max(quietPeriod - elapsedSinceRetirement, routeSettleDelay))
    }

    private func scheduleDrain(generation: UInt64, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0.05, delay)) { [weak self] in
            self?.drainIfStable(generation: generation)
        }
    }

    private func drainIfStable(generation: UInt64) {
        guard generation == self.generation else { return }
        guard !systemSleeping else {
            scheduleDrain(generation: generation, after: Self.quietPeriod)
            return
        }
        let delay = Self.releaseDelay(
            elapsedSinceRetirement: CFAbsoluteTimeGetCurrent() - latestRetirement,
            routeSettleDelay: AudioDeviceManager.shared.routeSettleDelay(window: Self.quietPeriod)
        )
        guard delay == 0 else {
            scheduleDrain(generation: generation, after: delay)
            return
        }
        let count = engines.count
        engines.removeAll()
        SapoLog.audioRoute.debug("Retired audio engines released count=\(count, privacy: .public)")
    }
}
