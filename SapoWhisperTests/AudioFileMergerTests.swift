//
//  AudioFileMergerTests.swift
//  SapoWhisperTests
//
//  Guards the continue-previous merge: two takes concatenate into one WAV,
//  converting the older take when its format (sample rate) differs.
//

import AVFoundation
import XCTest

@testable import SapoWhisper

final class AudioFileMergerTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-merger-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMergesSameFormatTakes() throws {
        let first = try writeTone(seconds: 2.0, sampleRate: 16_000, name: "first.wav")
        let second = try writeTone(seconds: 3.0, sampleRate: 16_000, name: "second.wav")

        let merged = try AudioFileMerger.merge(first: first, second: second)
        defer { try? FileManager.default.removeItem(at: merged) }

        let file = try AVAudioFile(forReading: merged)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 5.0, accuracy: 0.05)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)

        // Inputs stay intact.
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testMergesMixedSampleRatesIntoSecondFormat() throws {
        // Upload quality changed between takes: old 48 kHz, new 16 kHz.
        let first = try writeTone(seconds: 2.0, sampleRate: 48_000, name: "first48.wav")
        let second = try writeTone(seconds: 1.0, sampleRate: 16_000, name: "second16.wav")

        let merged = try AudioFileMerger.merge(first: first, second: second)
        defer { try? FileManager.default.removeItem(at: merged) }

        let file = try AVAudioFile(forReading: merged)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000, "output must use the current take's format")
        let duration = Double(file.length) / file.processingFormat.sampleRate
        XCTAssertEqual(duration, 3.0, accuracy: 0.1)
    }

    func testUnreadableFirstInputThrows() throws {
        let bogus = tempDir.appendingPathComponent("bogus.wav")
        try Data("not a wav".utf8).write(to: bogus)
        let second = try writeTone(seconds: 1.0, sampleRate: 16_000, name: "ok.wav")

        XCTAssertThrowsError(try AudioFileMerger.merge(first: bogus, second: second))
    }

    // MARK: - Helpers

    /// Writes a real int16 WAV with a 440 Hz tone via AVAudioFile, matching
    /// the recorder's writer.
    private func writeTone(seconds: TimeInterval, sampleRate: Double, name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false
        )!
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let samples = buffer.int16ChannelData![0]
        for frame in 0..<Int(frameCount) {
            let value = sin(2.0 * .pi * 440.0 * Double(frame) / sampleRate)
            samples[frame] = Int16(value * 8_000)
        }
        try file.write(from: buffer)
        return url
    }
}
