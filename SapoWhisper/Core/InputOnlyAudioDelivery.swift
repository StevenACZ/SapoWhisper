@preconcurrency import AVFoundation
import AudioToolbox
import Darwin
import Foundation

nonisolated final class InputOnlyAudioDelivery: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private let queue = DispatchQueue(label: "oli.SapoWhisper.input-delivery", qos: .userInitiated)
    private let source: DispatchSourceUserDataAdd
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let onError: @Sendable (OSStatus) -> Void
    private var writeIndex: Int32 = 0
    private var readIndex: Int32 = 0
    private var firstError: Int32 = 0
    private var errorDelivered = false

    init(
        format: AVAudioFormat, maximumFrames: AVAudioFrameCount, capacity: Int = 16,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (OSStatus) -> Void
    ) throws {
        guard capacity > 0, capacity < Int32.max, maximumFrames > 0,
            format.commonFormat == .pcmFormatFloat32, !format.isInterleaved
        else { throw RecordingError.invalidFormat }
        buffers = try (0...capacity).map { _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
                throw RecordingError.invalidFormat
            }
            return buffer
        }
        self.onBuffer = onBuffer
        self.onError = onError
        source = DispatchSource.makeUserDataAddSource(queue: queue)
        source.setEventHandler { [weak self] in self?.deliverPending() }
        source.resume()
    }

    deinit { source.cancel() }

    func activate() {
        queue.sync {
            let previous = OSAtomicAdd32Barrier(0, &firstError)
            _ = OSAtomicCompareAndSwap32Barrier(previous, 0, &firstError)
            errorDelivered = false
        }
    }

    // One AUHAL producer publishes copies; one serial consumer releases slots after its sink returns.
    func enqueue(_ input: AVAudioPCMBuffer) -> OSStatus {
        let failure = OSAtomicAdd32Barrier(0, &firstError)
        guard failure == noErr else { return failure }
        let index = OSAtomicAdd32Barrier(0, &writeIndex)
        let next = Int32((Int(index) + 1) % buffers.count)
        guard next != OSAtomicAdd32Barrier(0, &readIndex) else {
            return fail(kAudioUnitErr_TooManyFramesToProcess)
        }
        let target = buffers[Int(index)]
        guard input.frameLength <= target.frameCapacity,
            input.format == target.format,
            let inputChannels = input.floatChannelData, let outputChannels = target.floatChannelData
        else {
            return fail(kAudioUnitErr_InvalidPropertyValue)
        }
        target.frameLength = input.frameLength
        for channel in 0..<Int(target.format.channelCount) {
            memcpy(outputChannels[channel], inputChannels[channel], Int(input.frameLength) * MemoryLayout<Float>.size)
        }
        _ = OSAtomicCompareAndSwap32Barrier(index, next, &writeIndex)
        source.add(data: 1)
        return noErr
    }

    @discardableResult
    func fail(_ status: OSStatus) -> OSStatus {
        if status != noErr, OSAtomicCompareAndSwap32Barrier(0, status, &firstError) {
            source.add(data: 1)
        }
        return status
    }

    // Producers must stop before draining; sinks must not call lifecycle methods.
    func drain() { queue.sync { deliverPending() } }

    private func deliverPending() {
        while true {
            let index = OSAtomicAdd32Barrier(0, &readIndex)
            guard index != OSAtomicAdd32Barrier(0, &writeIndex) else { break }
            // Each sink owns this buffer until it returns and may modify its samples.
            onBuffer(buffers[Int(index)])
            let next = Int32((Int(index) + 1) % buffers.count)
            _ = OSAtomicCompareAndSwap32Barrier(index, next, &readIndex)
        }
        let error = OSAtomicAdd32Barrier(0, &firstError)
        if error != noErr, !errorDelivered {
            errorDelivered = true
            onError(error)
        }
    }
}
