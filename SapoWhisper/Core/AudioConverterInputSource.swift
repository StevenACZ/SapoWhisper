import AVFoundation
import os

nonisolated final class AudioConverterInputSource: Sendable {
    private enum InputError: Error { case invalidBufferRequest }

    private enum Source {
        case buffer(AVAudioPCMBuffer)
        case file(AVAudioFile, AVAudioFrameCount)
    }

    private struct State {
        let source: Source
        var exhausted = false
        var error: Error?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(buffer: AVAudioPCMBuffer) {
        state = OSAllocatedUnfairLock(uncheckedState: State(source: .buffer(buffer)))
    }

    init(file: AVAudioFile, maximumFrames: AVAudioFrameCount) {
        state = OSAllocatedUnfairLock(uncheckedState: State(source: .file(file, maximumFrames)))
    }

    var readError: Error? { state.withLock { $0.error } }

    // AVFAudio input objects stay owned by this conversion and are accessed only under this lock.
    func provide(
        _ packetCount: AVAudioPacketCount,
        _ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        state.withLockUnchecked { state in
            switch state.source {
            case .buffer(let buffer):
                guard !state.exhausted else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                state.exhausted = true
                outStatus.pointee = .haveData
                return buffer
            case .file(let file, let maximumFrames):
                guard !state.exhausted, file.framePosition < file.length else {
                    state.exhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard packetCount > 0,
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: min(packetCount, maximumFrames)
                    )
                else {
                    state.error = InputError.invalidBufferRequest
                    state.exhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer)
                } catch {
                    state.error = error
                    state.exhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard buffer.frameLength > 0 else {
                    state.exhausted = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }
        }
    }
}
