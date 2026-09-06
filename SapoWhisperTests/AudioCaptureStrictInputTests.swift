import Foundation
import Testing

@testable import SapoWhisper

@Suite("Strict microphone capture")
struct AudioCaptureStrictInputTests {
    @Test("A missing explicit input fails without starting a recording")
    @MainActor
    func missingExplicitInputFailsWithoutStartingRecording() async {
        let engine = AudioCaptureEngine(mode: .batch)
        engine.selectedDeviceUID = "missing-\(UUID().uuidString)"
        var unavailable = false

        do {
            try await engine.startRecording(targetEngine: .mlxWhisper)
        } catch RecordingError.inputDeviceUnavailable {
            unavailable = true
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        #expect(unavailable)
        #expect(engine.audioEngine == nil)
        #expect(!engine.isRecording)
    }

    @Test("An explicit healthy monitor ignores unrelated routes and never changes UID")
    func monitorRouteDecisionKeepsTheSelectedInput() {
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: false,
                selectedDeviceUID: "preferred-mic",
                selectedDeviceMatchesBoundRoute: true,
                engineIsRunning: true
            ) == .probe("preferred-mic")
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: false,
                selectedDeviceUID: "preferred-mic",
                selectedDeviceMatchesBoundRoute: false,
                engineIsRunning: true
            ) == .restart("preferred-mic")
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: false,
                selectedDeviceUID: AudioDevice.systemDefault.uid,
                selectedDeviceMatchesBoundRoute: true,
                engineIsRunning: true
            ) == .restart(AudioDevice.systemDefault.uid)
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: false,
                resumeAfterRecorder: false,
                selectedDeviceUID: "preferred-mic",
                selectedDeviceMatchesBoundRoute: true,
                engineIsRunning: true
            ) == .ignore
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: true,
                selectedDeviceUID: "preferred-mic",
                selectedDeviceMatchesBoundRoute: true,
                engineIsRunning: false
            ) == .ignore
        )
    }

    @Test("Only system default is warmed in the background")
    func explicitPreflightNeverOpensAnAudioEngine() {
        #expect(
            audioInputPreflightDecision(
                selectedUID: AudioDevice.systemDefault.uid,
                resolvedDeviceID: 2
            ) == .warmSystemDefault
        )
        #expect(
            audioInputPreflightDecision(
                selectedUID: "preferred-mic",
                resolvedDeviceID: 1
            ) == .skipExplicitAvailable
        )
        #expect(
            audioInputPreflightDecision(
                selectedUID: "preferred-mic",
                resolvedDeviceID: nil
            ) == .waitForExplicitInput
        )
    }

    @Test("Permission probing never opens a fallback for an explicit microphone")
    func permissionProbeHonorsExplicitSelection() {
        #expect(microphonePermissionShouldProbeAudioInput(selectedUID: AudioDevice.systemDefault.uid))
        #expect(!microphonePermissionShouldProbeAudioInput(selectedUID: "preferred-mic"))
        #expect(
            microphonePermissionShouldInvalidateCache(
                capturePermissionDenied: true,
                recordPermissionDenied: true
            )
        )
        #expect(
            !microphonePermissionShouldInvalidateCache(
                capturePermissionDenied: true,
                recordPermissionDenied: false
            )
        )
    }

    @Test("An explicit monitor probes real buffer health before keeping its engine")
    func explicitMonitorRequiresFreshBuffers() {
        #expect(
            audioLevelMonitorRouteIsHealthy(
                engineIsRunning: true,
                selectedDeviceMatchesBoundRoute: true,
                lastBufferAge: 0.1
            )
        )
        #expect(
            !audioLevelMonitorRouteIsHealthy(
                engineIsRunning: true,
                selectedDeviceMatchesBoundRoute: true,
                lastBufferAge: 0.75
            )
        )
        #expect(
            !audioLevelMonitorRouteIsHealthy(
                engineIsRunning: true,
                selectedDeviceMatchesBoundRoute: false,
                lastBufferAge: 0.1
            )
        )
        #expect(audioLevelMonitorHealthProbeDelay(transport: .bluetooth) == 3.0)
        #expect(
            audioLevelMonitorHealthProbeDelay(transport: .usb)
                > AudioCaptureEngine.captureHealthyBufferMaxAge
        )
    }

    @Test("Strict input guards precede every background audio engine")
    func strictInputGuardsPrecedeAudioEngines() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("SapoWhisper/Core")

        let monitor = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioLevelMonitor.swift"), encoding: .utf8)
        let monitorBody = try functionBody(
            in: monitor,
            start: "private nonisolated func startAudioEngineOnQueue",
            end: "private nonisolated func bindMonitorDevice"
        )
        try expectOrder(
            "resolveSelectedInputDeviceID",
            before: "let audioEngine = AVAudioEngine()",
            in: monitorBody
        )
        let monitorRouteBody = try functionBody(
            in: monitor,
            start: "private func handleAudioRouteChange",
            end: "private nonisolated func restartMonitorAfterInputRouteChange"
        )
        #expect(monitorRouteBody.contains("restartMonitorAfterInputRouteChange()"))
        #expect(!monitorRouteBody.contains("stopSampleRecording()"))
        let monitorRestartBody = try functionBody(
            in: monitor,
            start: "private nonisolated func restartMonitorAfterInputRouteChange",
            end: "private func scheduleMonitoringStart"
        )
        #expect(monitorRestartBody.contains("stopSampleForRouteRestart()"))

        let monitorSuspendBody = try functionBody(
            in: monitor,
            start: "func suspendForRecorder",
            end: "func resumeAfterRecorderIfNeeded"
        )
        #expect(monitorSuspendBody.contains("monitorQueue.sync"))
        #expect(!monitorSuspendBody.contains("monitorQueue.async"))

        let recovery = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioCaptureEngine+Device.swift"), encoding: .utf8)
        let recoveryBody = try functionBody(
            in: recovery,
            start: "private func rebuildCaptureEngine",
            end: "private func reportCaptureInterruption"
        )
        try expectOrder(
            "resolveSelectedInputDeviceID",
            before: "let engine = AVAudioEngine()",
            in: recoveryBody
        )

        let preflight = try String(
            contentsOf: sourceRoot.appendingPathComponent("Managers/AudioInputPreflightManager.swift"), encoding: .utf8)
        let preflightBody = try functionBody(
            in: preflight,
            start: "private static func prepare(",
            end: "private static func warmAVAudioInputNode("
        )
        try expectOrder(
            "audioInputPreflightDecision(",
            before: "warmAVAudioInputNode(hardwareFormat:",
            in: preflightBody
        )
        try expectOrder(
            "currentSelectedUID",
            before: "warmAVAudioInputNode(hardwareFormat:",
            in: preflightBody
        )

        let warmupBody = try functionBody(
            in: preflight,
            start: "private static func warmAVAudioInputNode(",
            end: "private static func queryInputFormat"
        )
        #expect(!warmupBody.contains("AudioUnitSetProperty"))

        let permission = try String(
            contentsOf: sourceRoot.appendingPathComponent("Permissions/MicrophonePermission.swift"), encoding: .utf8)
        let permissionRefreshBody = try functionBody(
            in: permission,
            start: "static func refreshFromAudioInputProbeIfNeeded",
            end: "private static var isCachedGranted"
        )
        try expectOrder(
            "microphonePermissionShouldProbeAudioInput",
            before: "probeAudioInput()",
            in: permissionRefreshBody
        )

        let capture = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioCaptureEngine.swift"), encoding: .utf8)

        for (fileName, className) in [
            ("DeepgramFluxLiveTranscriber.swift", "final class DeepgramFluxLiveTranscriber"),
            ("ElevenLabsScribeRealtimeTranscriber.swift", "final class ElevenLabsScribeRealtimeTranscriber"),
        ] {
            let streaming = try String(
                contentsOf: sourceRoot.appendingPathComponent(fileName), encoding: .utf8)
            let classStart = try #require(streaming.range(of: className))
            let sessionSource = String(streaming[classStart.lowerBound...])
            let cancelBody = try functionBody(
                in: sessionSource,
                start: "func cancel()",
                end: "func abortPreservingAudio()"
            )
            try expectOrder("cancelPendingSetup()", before: "discardRecording()", in: cancelBody)
        }
        let captureBody = try functionBody(
            in: capture,
            start: "func startRecording(targetEngine:",
            end: "func waitForFirstInputBuffer"
        )
        try expectOrder("refreshDevices()", before: "AudioEngineGuard.materializeInputNode", in: captureBody)
        try expectOrder(
            "resolveSelectedInputDeviceID",
            before: "AudioEngineGuard.materializeInputNode",
            in: captureBody
        )

        let resumeBody = try functionBody(
            in: capture,
            start: "func resumeRecording()",
            end: "func waitForFirstInputBuffer"
        )
        try expectOrder("teardownAndRetire", before: "audioEngine = nil", in: resumeBody)

        let deviceManager = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioDeviceManager.swift"), encoding: .utf8)
        let refreshBody = try functionBody(
            in: deviceManager,
            start: "nonisolated func refreshDevices",
            end: "private nonisolated func loadAvailableInputDevices"
        )
        #expect(refreshBody.contains("refreshQueue.sync"))

        let viewModel = try String(
            contentsOf: sourceRoot.appendingPathComponent("SapoWhisperViewModel.swift"), encoding: .utf8)
        let wakeBody = try functionBody(
            in: viewModel,
            start: "func handleSystemDidWake()",
            end: "var statusText"
        )
        try expectOrder("noteSystemWake()", before: "preflightSoon(reason: \"wake\")", in: wakeBody)
        let sleepBody = try functionBody(
            in: viewModel,
            start: "func handleSystemWillSleep()",
            end: "func handleApplicationWillTerminate()"
        )
        try expectOrder("noteSystemWillSleep()", before: "if isStartPending", in: sleepBody)

        let startSessionBody = try functionBody(
            in: viewModel,
            start: "private func startCaptureSession",
            end: "// MARK: - No-speech handling"
        )
        try expectOrder(
            "recorderDidStart = true",
            before: "setMicConnecting(deviceName: nil)",
            in: startSessionBody
        )

        let englishStrings = try String(
            contentsOf:
                sourceRoot
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )
        #expect(englishStrings.contains("error.configured_microphone_unavailable"))
    }

    private func functionBody(in source: String, start: String, end: String) throws -> String {
        let suffix = try #require(source.components(separatedBy: start).dropFirst().first)
        return try #require(suffix.components(separatedBy: end).first)
    }

    private func expectOrder(_ first: String, before second: String, in source: String) throws {
        let firstRange = try #require(source.range(of: first))
        let secondRange = try #require(source.range(of: second))
        #expect(firstRange.lowerBound < secondRange.lowerBound)
    }
}
