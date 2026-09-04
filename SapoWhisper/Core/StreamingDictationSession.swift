//
//  StreamingDictationSession.swift
//  SapoWhisper
//
//  One live streaming transcriber (WebSocket + local capture) as the
//  ViewModel drives it. Both streaming engines expose the exact same
//  lifecycle; conforming them lets the ViewModel keep ONE start/stop/pause/
//  abort/binding path instead of a near-identical copy per engine.
//

import Combine
import Foundation

/// Final output of a live streaming dictation: the accumulated transcript
/// plus the locally captured WAV backing it.
struct StreamingDictationResult {
    let transcript: String
    let audioURL: URL
    let duration: TimeInterval
    let language: String
    let diagnostics: RecordingCaptureDiagnostics
    let transcriptionVariant: TranscriptionEngineVariant
}

@MainActor
protocol StreamingDictationSession: AnyObject {
    var isStreaming: Bool { get }
    var isPaused: Bool { get }
    var recordingDuration: TimeInterval { get }
    /// Last locally captured WAV, for failure paths that preserve audio.
    var lastCaptureResult: AudioCaptureResult? { get }
    var onCaptureInterrupted: ((String) -> Void)? { get set }

    var isStreamingPublisher: AnyPublisher<Bool, Never> { get }
    var recordingDurationPublisher: AnyPublisher<TimeInterval, Never> { get }
    var audioLevelPublisher: AnyPublisher<Float, Never> { get }

    func start(microphone: String, language: String) async throws
    func sealCapture() -> AudioCaptureResult?
    func finalizeTranscription() async throws -> StreamingDictationResult
    func cancel()
    func pauseRecording()
    func resumeRecording() throws
    func abortPreservingAudio() -> AudioCaptureResult?
}
