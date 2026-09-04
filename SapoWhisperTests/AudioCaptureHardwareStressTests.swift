import XCTest

@testable import SapoWhisper

@MainActor
final class AudioCaptureHardwareStressTests: XCTestCase {
    func testRepeatedCaptureOnExplicitInput() async throws {
        guard ProcessInfo.processInfo.environment["SAPO_CAPTURE_STRESS"] == "1" else {
            throw XCTSkip("Explicit opt-in required for microphone capture")
        }
        guard MicrophonePermission.isGranted else {
            throw XCTSkip("Existing microphone permission required; never request it from this test")
        }
        let microphone = UserDefaults.standard.string(forKey: Constants.StorageKeys.selectedMicrophone) ?? "default"
        guard microphone != AudioDevice.systemDefault.uid else {
            throw XCTSkip("An explicit input must be selected")
        }
        var startTimes: [TimeInterval] = []
        var totalBuffers = 0
        for mode in [AudioCaptureEngine.Mode.batch, .streaming] {
            let capture = AudioCaptureEngine(mode: mode)
            let supervisor = CaptureStartSupervisor(recorder: capture, mode: mode)
            for _ in 0..<15 {
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    try await supervisor.start(microphone: microphone, targetEngine: .localAIServer)
                    startTimes.append(ProcessInfo.processInfo.systemUptime - started)
                    let stopped = await capture.stopRecordingAsync()
                    let result = try XCTUnwrap(stopped)
                    defer { capture.deleteRecording(at: result.audioURL) }
                    XCTAssertTrue(result.diagnostics.receivedInput)
                    XCTAssertTrue(result.diagnostics.isComplete)
                    XCTAssertGreaterThan(result.diagnostics.writtenFrameCount, 0)
                    totalBuffers += result.diagnostics.inputBufferCount
                } catch {
                    capture.discardRecording()
                    throw error
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let sorted = startTimes.sorted()
        print(
            "capture-stress runs=\(sorted.count) buffers=\(totalBuffers) p50Ms=\(Int(sorted[14] * 1000)) maxMs=\(Int((sorted.last ?? 0) * 1000))"
        )
    }
}
