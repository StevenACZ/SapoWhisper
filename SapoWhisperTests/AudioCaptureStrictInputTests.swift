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

    @Test("A requested monitor restarts the same input after route changes")
    func monitorRouteDecisionKeepsTheSelectedInput() {
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: false,
                selectedDeviceUID: "preferred-mic"
            ) == .restart("preferred-mic")
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: false,
                resumeAfterRecorder: false,
                selectedDeviceUID: "preferred-mic"
            ) == .ignore
        )
        #expect(
            audioLevelMonitorRouteAction(
                monitoringRequested: true,
                resumeAfterRecorder: true,
                selectedDeviceUID: "preferred-mic"
            ) == .ignore
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
        try expectOrder(
            "restartMonitorAfterInputRouteChange()",
            before: "stopSampleRecording()",
            in: monitorRouteBody
        )

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
            start: "private func runPreflight",
            end: "private func warmAVAudioInputNode"
        )
        try expectOrder(
            "selected-input-unavailable",
            before: "warmAVAudioInputNode(deviceID:",
            in: preflightBody
        )

        let warmupBody = try functionBody(
            in: preflight,
            start: "private func warmAVAudioInputNode",
            end: "private func queryInputFormat"
        )
        try expectOrder(
            "guard status == noErr",
            before: "AudioEngineGuard.prepareAndStart",
            in: warmupBody
        )

        let capture = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioCaptureEngine.swift"), encoding: .utf8)
        let captureBody = try functionBody(
            in: capture,
            start: "func startRecording(targetEngine:",
            end: "func waitForFirstInputBuffer"
        )
        try expectOrder("refreshDevices()", before: "let localEngine = AVAudioEngine()", in: captureBody)
        try expectOrder(
            "resolveSelectedInputDeviceID",
            before: "let localEngine = AVAudioEngine()",
            in: captureBody
        )

        let deviceManager = try String(
            contentsOf: sourceRoot.appendingPathComponent("AudioDeviceManager.swift"), encoding: .utf8)
        let refreshBody = try functionBody(
            in: deviceManager,
            start: "nonisolated func refreshDevices",
            end: "private nonisolated func loadAvailableInputDevices"
        )
        #expect(refreshBody.contains("refreshQueue.sync"))
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
