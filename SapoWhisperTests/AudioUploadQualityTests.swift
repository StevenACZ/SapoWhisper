//
//  AudioUploadQualityTests.swift
//  SapoWhisperTests
//

import AVFoundation
import Darwin
import XCTest

@testable import SapoWhisper

nonisolated final class AudioUploadQualityTests: XCTestCase {

    func testStoredQualityDefaultsToMedium() throws {
        let suiteName = "test.sapowhisper.audio-quality.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AudioUploadQuality.stored(in: defaults), .medium)

        defaults.set("not-a-quality", forKey: Constants.StorageKeys.audioUploadQuality)
        XCTAssertEqual(AudioUploadQuality.stored(in: defaults), .medium)
    }

    func testUploadQualityFormats() throws {
        let input48k = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        let input96k = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 96_000, channels: 1, interleaved: false)
        )
        let input44k = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)
        )

        XCTAssertEqual(AudioUploadQuality.ultraFast.audioFormat(matching: input48k).sampleRate, 16_000)
        XCTAssertEqual(AudioUploadQuality.ultraFast.audioFormat(matching: input48k).commonFormat, .pcmFormatInt16)

        XCTAssertEqual(AudioUploadQuality.medium.audioFormat(matching: input48k).sampleRate, 24_000)
        XCTAssertEqual(AudioUploadQuality.medium.audioFormat(matching: input48k).commonFormat, .pcmFormatInt16)

        XCTAssertEqual(AudioUploadQuality.high.audioFormat(matching: input48k).sampleRate, 48_000)
        XCTAssertEqual(AudioUploadQuality.high.audioFormat(matching: input96k).sampleRate, 48_000)
        XCTAssertEqual(AudioUploadQuality.high.audioFormat(matching: input44k).sampleRate, 44_100)
        XCTAssertEqual(AudioUploadQuality.high.audioFormat(matching: input48k).commonFormat, .pcmFormatInt16)

        XCTAssertEqual(AudioUploadQuality.ultraOriginal.audioFormat(matching: input48k).sampleRate, 48_000)
        XCTAssertEqual(AudioUploadQuality.ultraOriginal.audioFormat(matching: input48k).commonFormat, .pcmFormatFloat32)
    }

    /// Whisper-family engines decode at 16 kHz: the STT-oriented qualities
    /// capture 16 kHz directly (no double resample at medium), while the
    /// fidelity-oriented ones keep the user's explicit choice, and non-whisper
    /// engines are unaffected.
    func testWhisperFamilyEnginesCaptureSixteenKilohertzDirectly() throws {
        let input48k = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )

        for engine in [TranscriptionEngine.whisperLocal, .localAIServer] {
            let mediumFormat = AudioUploadQuality.medium.audioFormat(matching: input48k, for: engine)
            XCTAssertEqual(mediumFormat.sampleRate, 16_000)
            XCTAssertEqual(mediumFormat.commonFormat, .pcmFormatInt16)
            XCTAssertEqual(AudioUploadQuality.ultraFast.audioFormat(matching: input48k, for: engine).sampleRate, 16_000)
            XCTAssertEqual(AudioUploadQuality.high.audioFormat(matching: input48k, for: engine).sampleRate, 48_000)
            XCTAssertEqual(
                AudioUploadQuality.ultraOriginal.audioFormat(matching: input48k, for: engine).sampleRate, 48_000
            )
        }

        XCTAssertEqual(AudioUploadQuality.medium.audioFormat(matching: input48k, for: .deepgram).sampleRate, 24_000)
        XCTAssertEqual(
            AudioUploadQuality.medium.audioFormat(matching: input48k, for: .elevenLabsScribe).sampleRate, 24_000
        )
        XCTAssertEqual(AudioUploadQuality.medium.audioFormat(matching: input48k, for: nil).sampleRate, 24_000)
    }

    func testRealtimeReplayConvertsFloatWAVToPCM16Mono16k() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sapowhisper-replay-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sourceFormat = try XCTUnwrap(
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
        )
        do {
            let file = try AVAudioFile(
                forWriting: tempURL,
                settings: sourceFormat.settings,
                commonFormat: sourceFormat.commonFormat,
                interleaved: sourceFormat.isInterleaved
            )
            let frameCount = AVAudioFrameCount(12_000)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount))
            buffer.frameLength = frameCount
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<Int(frameCount) {
                channel[index] = Float(sin(Double(index) / 24.0)) * 0.2
            }
            try file.write(from: buffer)
        }

        let pcmData = try ElevenLabsScribeRealtimeTranscriber.extractPCM16MonoData(from: tempURL)

        XCTAssertEqual(pcmData.count % MemoryLayout<Int16>.size, 0)
        XCTAssertGreaterThan(pcmData.count, 7_800)
        XCTAssertLessThan(pcmData.count, 8_200)
    }
}
