import AVFoundation
import XCTest
import os

@testable import SapoWhisper

nonisolated final class AudioConverterInputSourceTests: XCTestCase {
    func testBufferIsProvidedExactlyOnceAcrossConcurrentPulls() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        let source = AudioConverterInputSource(buffer: buffer)
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            var inputStatus = AVAudioConverterInputStatus.noDataNow
            if source.provide(32, &inputStatus) != nil {
                delivered.withLock { $0 += 1 }
            }
        }
        XCTAssertEqual(delivered.withLock { $0 }, 1)
    }

    func testFileConversionDrainsAllFramesWithoutReadingAtEOF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("input.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
        buffer.frameLength = 4410
        for frame in 0..<4410 { buffer.floatChannelData![0][frame] = 0.2 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let file = try AVAudioFile(forReading: url)
        let target = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: target))
        let source = AudioConverterInputSource(file: file, maximumFrames: 512)
        var frames = 0
        var reachedEnd = false
        for _ in 0..<30 {
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 256))
            let result = converter.convert(to: output, error: nil, withInputFrom: source.provide)
            frames += Int(output.frameLength)
            XCTAssertNotEqual(result, .error)
            if result == .endOfStream {
                reachedEnd = true
                break
            }
        }
        XCTAssertTrue(reachedEnd)
        XCTAssertEqual(Double(frames), 1600, accuracy: 1)
        XCTAssertNil(source.readError)
        var inputStatus = AVAudioConverterInputStatus.haveData
        XCTAssertNil(source.provide(512, &inputStatus))
        XCTAssertEqual(inputStatus, .endOfStream)
        XCTAssertNil(source.readError)
    }
}
