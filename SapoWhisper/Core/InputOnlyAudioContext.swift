@preconcurrency import AVFoundation
import AudioToolbox
import Darwin

nonisolated final class InputOnlyAudioContext: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let unit: AudioUnit
    private let delivery: InputOnlyAudioDelivery
    private var accepting: Int32 = 0
    private var callbacksInFlight: Int32 = 0
    private var errorReported: Int32 = 0

    init(
        unit: AudioUnit, format: AVAudioFormat, maximumFrames: AVAudioFrameCount,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onError: @escaping @Sendable (OSStatus) -> Void
    ) throws {
        guard maximumFrames > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames)
        else { throw RecordingError.invalidFormat }
        self.unit = unit
        self.buffer = buffer
        delivery = try InputOnlyAudioDelivery(
            format: format, maximumFrames: maximumFrames, onBuffer: onBuffer, onError: onError
        )
    }

    func activate() {
        delivery.activate()
        _ = OSAtomicCompareAndSwap32Barrier(1, 0, &errorReported)
        _ = OSAtomicCompareAndSwap32Barrier(0, 1, &accepting)
    }

    func deactivate() {
        _ = OSAtomicCompareAndSwap32Barrier(1, 0, &accepting)
    }

    func waitForCallbacks() {
        while OSAtomicAdd32Barrier(0, &callbacksInFlight) != 0 { usleep(500) }
        delivery.drain()
    }

    func drainDelivery() { delivery.drain() }

    func reportError(_ status: OSStatus) {
        deactivate()
        if OSAtomicCompareAndSwap32Barrier(0, 1, &errorReported) { delivery.fail(status) }
    }

    func render(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>, frameCount: AVAudioFrameCount
    ) -> OSStatus {
        OSAtomicIncrement32Barrier(&callbacksInFlight)
        defer { OSAtomicDecrement32Barrier(&callbacksInFlight) }
        guard OSAtomicAdd32Barrier(0, &accepting) == 1 else { return noErr }
        guard frameCount <= buffer.frameCapacity else {
            reportError(kAudioUnitErr_TooManyFramesToProcess)
            return kAudioUnitErr_TooManyFramesToProcess
        }
        guard frameCount > 0 else { return noErr }
        buffer.frameLength = frameCount
        let status = AudioUnitRender(unit, flags, timestamp, 1, frameCount, buffer.mutableAudioBufferList)
        guard status == noErr else {
            reportError(status)
            return status
        }
        let deliveryStatus = delivery.enqueue(buffer)
        if deliveryStatus != noErr { reportError(deliveryStatus) }
        return deliveryStatus
    }
}

nonisolated let inputOnlyAudioCallback: AURenderCallback = {
    reference, flags, timestamp, _, frameCount, _ in
    let context = Unmanaged<InputOnlyAudioContext>.fromOpaque(reference).takeUnretainedValue()
    return context.render(flags: flags, timestamp: timestamp, frameCount: frameCount)
}
