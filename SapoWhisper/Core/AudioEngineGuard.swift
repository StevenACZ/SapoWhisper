//
//  AudioEngineGuard.swift
//  SapoWhisper
//

// AVFAudio tap blocks predate Sendable annotations (same discipline as the
// capture files that pass them through this guard).
@preconcurrency import AVFAudio
@preconcurrency import Combine
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

    static func inputSetupDeadline(
        inputTransport: AudioDeviceTransport,
        outputTransport: AudioDeviceTransport
    ) -> TimeInterval {
        inputTransport == .bluetooth || outputTransport == .bluetooth ? 5 : 3
    }

    final class MaterializedInput: @unchecked Sendable {
        let engine: AVAudioEngine
        let node: AVAudioInputNode
        let tapFormat: AVAudioFormat

        init(engine: AVAudioEngine, node: AVAudioInputNode, tapFormat: AVAudioFormat) {
            self.engine = engine
            self.node = node
            self.tapFormat = tapFormat
        }
    }

    static func run<T>(_ operation: String, _ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        let exception = SapoWhisperCatchObjCException {
            result = Result(catching: body)
        }
        if let exception {
            let name = exception.name.rawValue
            let reason = exception.reason ?? "unknown"
            SapoLog.recording.error(
                "AVFAudio ObjC exception caught operation=\(operation, privacy: .public) name=\(name, privacy: .public) reason=\(reason, privacy: .private(mask: .hash))"
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

    static func materializeInputNode(
        deadline: TimeInterval,
        inputTransport: AudioDeviceTransport,
        outputTransport: AudioDeviceTransport,
        operation: String,
        prepare: @escaping @Sendable (AVAudioInputNode) throws -> AVAudioFormat
    ) async throws -> MaterializedInput {
        let epoch = AudioInputSetupQuarantine.shared.currentEpoch
        guard AudioInputSetupQuarantine.shared.canAttempt(epoch: epoch) else {
            SapoLog.recording.error(
                "Audio input setup quarantined phase=materialize inputTransport=\(inputTransport.rawValue, privacy: .public) outputTransport=\(outputTransport.rawValue, privacy: .public)"
            )
            throw RecordingError.inputSetupTimedOut
        }

        let request = AudioDeadlineRequest<MaterializedInput>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let attempt = AudioDeadlineAttempt(
                    timeout: deadline,
                    operation: operation,
                    work: {
                        let engine = AVAudioEngine()
                        do {
                            let node = try inputNode(of: engine, operation: operation)
                            let tapFormat = try prepare(node)
                            return MaterializedInput(engine: engine, node: node, tapFormat: tapFormat)
                        } catch {
                            teardownAndRetire(engine, removeInputTap: false, operation: "\(operation)-failure")
                            throw error
                        }
                    },
                    cleanup: {
                        teardownAndRetire($0.engine, removeInputTap: false, operation: "\(operation)-late")
                    },
                    onQuarantine: { timedOut in
                        AudioInputSetupQuarantine.shared.quarantineCurrentEpoch()
                        let reason = timedOut ? "timeout" : "cancel-in-flight"
                        SapoLog.recording.error(
                            "Audio input setup quarantined phase=materialize reason=\(reason, privacy: .public) inputTransport=\(inputTransport.rawValue, privacy: .public) outputTransport=\(outputTransport.rawValue, privacy: .public) timeoutMs=\(Int(deadline * 1000), privacy: .public)"
                        )
                    },
                    completion: { continuation.resume(with: $0) }
                )
                request.install(attempt)
                attempt.start()
            }
        } onCancel: {
            request.cancel()
        }
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

nonisolated final class AudioDeadlineRequest<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var attempt: AudioDeadlineAttempt<Value>?
    private var cancelled = false

    func install(_ attempt: AudioDeadlineAttempt<Value>) {
        lock.lock()
        self.attempt = attempt
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel {
            attempt.cancel()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let attempt = self.attempt
        lock.unlock()
        attempt?.cancel()
    }
}

nonisolated final class AudioDeadlineAttempt<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let operation: String
    private let worker: DispatchQueue
    private let timer: DispatchQueue
    private let work: @Sendable () throws -> Value
    private let cleanup: @Sendable (Value) -> Void
    private let onQuarantine: @Sendable (Bool) -> Void
    private let completion: @Sendable (Result<Value, Error>) -> Void
    private var started = false
    private var workStarted = false
    private var workerFinished = false
    private var completionDelivered = false
    private var quarantineDelivered = false

    init(
        timeout: TimeInterval,
        operation: String,
        worker: DispatchQueue = DispatchQueue(label: "com.sapowhisper.audioInput.deadline", qos: .userInitiated),
        timer: DispatchQueue = DispatchQueue(label: "com.sapowhisper.audioInput.deadline.timer", qos: .userInitiated),
        work: @escaping @Sendable () throws -> Value,
        cleanup: @escaping @Sendable (Value) -> Void,
        onQuarantine: @escaping @Sendable (Bool) -> Void = { _ in },
        completion: @escaping @Sendable (Result<Value, Error>) -> Void
    ) {
        self.timeout = timeout
        self.operation = operation
        self.worker = worker
        self.timer = timer
        self.work = work
        self.cleanup = cleanup
        self.onQuarantine = onQuarantine
        self.completion = completion
    }

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        if completionDelivered {
            workerFinished = true
            lock.unlock()
            return
        }
        lock.unlock()

        worker.async { [self] in
            lock.lock()
            guard !completionDelivered else {
                workerFinished = true
                lock.unlock()
                return
            }
            workStarted = true
            lock.unlock()

            let result = Result(catching: work)
            lock.lock()
            workerFinished = true
            let shouldComplete = !completionDelivered
            if shouldComplete {
                completionDelivered = true
            }
            lock.unlock()

            if shouldComplete {
                completion(result)
            } else if case .success(let value) = result {
                cleanup(value)
            }
        }

        timer.asyncAfter(deadline: .now() + timeout) { [self] in
            timeoutIfNeeded()
        }
    }

    func cancel() {
        lock.lock()
        guard !completionDelivered else {
            lock.unlock()
            return
        }
        completionDelivered = true
        lock.unlock()
        completion(.failure(CancellationError()))
    }

    private func timeoutIfNeeded() {
        lock.lock()
        guard !workerFinished, !completionDelivered || workStarted else {
            lock.unlock()
            return
        }
        let shouldComplete = !completionDelivered
        completionDelivered = true
        let shouldQuarantine = workStarted && !quarantineDelivered
        if shouldQuarantine {
            quarantineDelivered = true
        }
        lock.unlock()
        if shouldQuarantine {
            onQuarantine(true)
        }
        SapoLog.recording.error("Audio input setup timed out operation=\(self.operation, privacy: .public)")
        if shouldComplete {
            completion(.failure(RecordingError.inputSetupTimedOut))
        }
    }
}

nonisolated final class AudioInputSetupQuarantine: @unchecked Sendable {
    static let shared = AudioInputSetupQuarantine()

    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var quarantinedEpoch: UInt64?
    private var routeSubscription: AnyCancellable?

    var currentEpoch: UInt64 {
        lock.withLock { epoch }
    }

    func canAttempt(epoch: UInt64) -> Bool {
        lock.withLock { quarantinedEpoch != epoch }
    }

    func quarantine(epoch: UInt64) {
        lock.withLock {
            guard self.epoch == epoch else { return }
            quarantinedEpoch = epoch
        }
    }

    func quarantineCurrentEpoch() {
        lock.withLock {
            quarantinedEpoch = epoch
        }
    }

    func advanceRouteEpoch() {
        lock.withLock {
            epoch &+= 1
            quarantinedEpoch = nil
        }
    }

    @MainActor
    func observeRouteChanges() {
        observeRouteChanges(AudioDeviceManager.shared.routeChanges)
    }

    @MainActor
    func observeRouteChanges(_ routeChanges: AnyPublisher<Void, Never>) {
        guard routeSubscription == nil else { return }
        routeSubscription = routeChanges.sink { [weak self] in
            self?.advanceRouteEpoch()
        }
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
