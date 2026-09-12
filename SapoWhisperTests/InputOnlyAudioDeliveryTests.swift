import AVFoundation
import AudioToolbox
import XCTest

@testable import SapoWhisper

final class InputOnlyAudioDeliveryTests: XCTestCase {
    func testOrderedIndependentBuffersAndBoundedOverflow() throws {
        let probe = InputDeliveryProbe()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
            ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let delivery = try InputOnlyAudioDelivery(
            format: format, maximumFrames: 4, capacity: 3,
            onBuffer: { buffer in
                if buffer.floatChannelData![0][0] == 1 {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 3)
                }
                probe.record(buffer)
                buffer.floatChannelData![0][0] = -99
            }, onError: { probe.record($0) }
        )
        fill(input, value: 1)
        XCTAssertEqual(delivery.enqueue(input), noErr)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        fill(input, value: 2)
        XCTAssertEqual(delivery.enqueue(input), noErr)
        fill(input, value: 3)
        XCTAssertEqual(delivery.enqueue(input), noErr)
        fill(input, value: 4)
        XCTAssertEqual(delivery.enqueue(input), kAudioUnitErr_TooManyFramesToProcess)
        XCTAssertEqual(delivery.enqueue(input), kAudioUnitErr_TooManyFramesToProcess)
        release.signal()
        delivery.drain()
        XCTAssertEqual(probe.samples, [1, 2, 3].map { Array(repeating: Float($0), count: 8) })
        XCTAssertEqual(probe.errors, [kAudioUnitErr_TooManyFramesToProcess])
        XCTAssertEqual(input.floatChannelData![0][0], 4)

        delivery.activate()
        fill(input, value: 5)
        XCTAssertEqual(delivery.enqueue(input), noErr)
        delivery.drain()
        XCTAssertEqual(probe.samples.last, Array(repeating: 5, count: 8))
    }

    func testDrainWaitsForAcceptedSinkAndReportsErrorOnDeliveryQueue() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let drained = DispatchSemaphore(value: 0)
        let probe = InputDeliveryProbe()
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let delivery = try InputOnlyAudioDelivery(
            format: format, maximumFrames: 4,
            onBuffer: { buffer in
                entered.signal()
                _ = release.wait(timeout: .now() + 3)
                probe.record(buffer)
            }, onError: { probe.record($0) }
        )
        fill(input, value: 7)
        XCTAssertEqual(delivery.enqueue(input), noErr)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        delivery.fail(kAudioUnitErr_CannotDoInCurrentContext)
        XCTAssertTrue(probe.errors.isEmpty)
        DispatchQueue.global().async {
            delivery.drain()
            drained.signal()
        }
        XCTAssertEqual(drained.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(probe.samples, [Array(repeating: 7, count: 4)])
        XCTAssertEqual(probe.errors, [kAudioUnitErr_CannotDoInCurrentContext])
    }

    func testOversizedBufferFailsWithoutDeliveryOrOverflowingStorage() throws {
        let probe = InputDeliveryProbe()
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
            ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        let delivery = try InputOnlyAudioDelivery(
            format: format, maximumFrames: 4,
            onBuffer: { probe.record($0) }, onError: { probe.record($0) }
        )
        fill(input, value: 9)
        XCTAssertEqual(delivery.enqueue(input), kAudioUnitErr_InvalidPropertyValue)
        delivery.drain()
        XCTAssertTrue(probe.samples.isEmpty)
        XCTAssertEqual(probe.errors, [kAudioUnitErr_InvalidPropertyValue])
    }

    func testRingWraparoundAcrossManyProducerConsumerHandoffs() throws {
        let probe = InputDeliveryProbe()
        let delivered = DispatchSemaphore(value: 0)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false
            ))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let delivery = try InputOnlyAudioDelivery(
            format: format, maximumFrames: 4, capacity: 2,
            onBuffer: {
                probe.record($0)
                delivered.signal()
            }, onError: { probe.record($0) }
        )
        for value in 0..<2_000 {
            fill(input, value: Float(value))
            XCTAssertEqual(delivery.enqueue(input), noErr)
            guard delivered.wait(timeout: .now() + 2) == .success else {
                return XCTFail("Delivery did not complete handoff \(value)")
            }
        }
        delivery.drain()
        XCTAssertEqual(probe.samples, (0..<2_000).map { Array(repeating: Float($0), count: 8) })
        XCTAssertTrue(probe.errors.isEmpty)
    }

    private func fill(_ buffer: AVAudioPCMBuffer, value: Float) {
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = value }
        }
    }
}

private nonisolated final class InputDeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSamples: [[Float]] = []
    private var recordedErrors: [OSStatus] = []

    var samples: [[Float]] { lock.withLock { recordedSamples } }
    var errors: [OSStatus] { lock.withLock { recordedErrors } }

    func record(_ buffer: AVAudioPCMBuffer) {
        let samples = (0..<Int(buffer.format.channelCount)).flatMap { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        lock.withLock { recordedSamples.append(samples) }
    }

    func record(_ status: OSStatus) { lock.withLock { recordedErrors.append(status) } }
}
