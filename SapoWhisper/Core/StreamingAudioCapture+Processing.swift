//
//  StreamingAudioCapture+Processing.swift
//  SapoWhisper
//

// AVFAudio's converter/tap callbacks predate Sendable annotations; buffers are
// handed off queue-to-queue under the class's own synchronization.
@preconcurrency import AVFAudio
import AVFoundation
import Foundation
import os

nonisolated extension StreamingAudioCapture {
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile, let outputFormat = converterOutputFormat else { return }
        let inputTime = CFAbsoluteTimeGetCurrent()
        let bufferStats = registerInputBuffer(at: inputTime)
        if let gapMs = bufferStats.gapMs, gapMs > 250 {
            SapoLog.recording.warning(
                "Flux input gap detected gap=\(Int(gapMs), privacy: .public)ms buffer=\(bufferStats.count, privacy: .public)"
            )
        }
        if bufferStats.count % 100 == 0 {
            SapoLog.recording.info(
                "Flux input progress buffers=\(bufferStats.count, privacy: .public) frames=\(self.writtenFrameCount, privacy: .public)"
            )
        }
        // lastInputBufferTime is now published under captureStateLock inside
        // registerInputBuffer(at:) above — do not write it bare here.
        logFirstInputBufferIfNeeded(buffer: buffer, inputTime: inputTime)

        // Gain runs on the raw tap buffer BEFORE conversion: amplifying the
        // already-quantized int16 output hard-clipped at high gain settings
        // and threw away the float headroom the limiter needs.
        applyGainIfNeeded(to: buffer)

        converterLock.lock()
        defer { converterLock.unlock() }

        // A2: rebuilt when the tap format changes mid-capture (route recovery rebinds the input).
        if converter == nil || converter?.inputFormat != buffer.format {
            if converter != nil {
                SapoLog.recording.info(
                    "Streaming tap format changed, rebuilding converter inHz=\(Int(buffer.format.sampleRate), privacy: .public)"
                )
            }
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            // Mastering-grade sample rate conversion: the default SRC's
            // anti-aliasing is mediocre for the 48k→16k hop.
            converter?.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        }
        guard let converter else { return }

        let capacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        var didPublishLevel = false
        // The input block runs synchronously inside convert(); the lock only
        // satisfies the Sendable contract of the SDK callback.
        let inputConsumed = OSAllocatedUnfairLock(initialState: false)

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                let alreadyConsumed = inputConsumed.withLock { (consumed: inout Bool) -> Bool in
                    if consumed { return true }
                    consumed = true
                    return false
                }
                if alreadyConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData:
                writeAndEmit(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                didPublishLevel = true
            case .inputRanDry, .endOfStream:
                // The converter can hand back a short tail together with
                // inputRanDry — emit it instead of dropping those frames.
                if convertedBuffer.frameLength > 0 {
                    writeAndEmit(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                }
                return
            case .error:
                SapoLog.flux.error(
                    "Capture conversion failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return
            @unknown default:
                return
            }
        }
    }

    func writeAndEmit(_ buffer: AVAudioPCMBuffer, to audioFile: AVAudioFile, publishLevel: Bool) {
        guard buffer.frameLength > 0 else { return }
        // Gain was already applied to the tap buffer before conversion, so the
        // published level below still reflects the post-gain signal.
        if publishLevel { publishAudioLevel(from: buffer) }

        // Emit to the streaming engine first: the WAV is the local backup and
        // a slow (or failing) disk must never delay or drop live chunks.
        if let data = pcmData(from: buffer) {
            let chunkCount = registerEmittedChunk()
            if chunkCount % 100 == 0 {
                SapoLog.flux.info("Flux local audio chunks emitted count=\(chunkCount, privacy: .public)")
            }
            chunkHandler?(data)
        }

        // A1: the disk write runs on a dedicated serial queue; the stop path
        // drains it before closing the file.
        audioWriteQueue.async { [weak self] in
            do {
                try audioFile.write(from: buffer)
                self?.registerWrittenFrames(buffer.frameLength)
            } catch {
                SapoLog.flux.error(
                    "Capture write failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    func publishAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let channelData = buffer.int16ChannelData else { return }
        let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
        var sum: Float = 0
        for sample in samples {
            let normalized = Float(sample) / Float(Int16.max)
            sum += normalized * normalized
        }

        let rms = sqrt(sum / Float(frameLength))
        let avgPower = 20 * log10(max(rms, 0.0001))
        let normalized = max(0, min(1, (avgPower + 60) / 60))
        smoothedAudioLevel = (smoothedAudioLevel * 0.7) + (normalized * 0.3)

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastAudioLevelPublishTime >= 0.05 else { return }
        lastAudioLevelPublishTime = now
        let level = smoothedAudioLevel
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }
    }

    /// Applies capture gain to the raw tap buffer before conversion, with a
    /// soft limiter instead of a hard clip: linear below the knee, smooth tanh
    /// compression above it, asymptotic to full scale. High gain settings (the
    /// slider allows up to 40x) compress peaks instead of squaring them off,
    /// which every downstream engine hears as distortion.
    func applyGainIfNeeded(to buffer: AVAudioPCMBuffer) {
        guard activeGain != 1 else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)
        let gain = activeGain

        if let channelData = buffer.floatChannelData {
            for channel in 0..<channelCount {
                let samples = channelData[channel]
                for index in 0..<frameCount {
                    samples[index] = Self.softLimitedSample(samples[index], gain: gain)
                }
            }
            return
        }

        guard let channelData = buffer.int16ChannelData else { return }
        let scale = Float(Int16.max)

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for index in 0..<frameCount {
                let normalized = Float(samples[index]) / scale
                samples[index] = Int16(Self.softLimitedSample(normalized, gain: gain) * scale)
            }
        }
    }

    /// Identity below the knee, tanh compression above it, asymptote at ±1 —
    /// so the later int16 conversion can never hard-clip a gained sample.
    static let softLimiterKnee: Float = 0.85

    static func softLimitedSample(_ sample: Float, gain: Float) -> Float {
        let amplified = sample * gain
        let magnitude = abs(amplified)
        guard magnitude > softLimiterKnee else { return amplified }
        let headroom = 1 - softLimiterKnee
        let limited = softLimiterKnee + headroom * tanhf((magnitude - softLimiterKnee) / headroom)
        return amplified < 0 ? -limited : limited
    }

    func flushRemainingConvertedAudio() -> AVAudioFrameCount {
        guard let converter, let outputFormat = converterOutputFormat, let audioFile else { return 0 }
        converterLock.lock()
        defer { converterLock.unlock() }

        var frames: AVAudioFrameCount = 0
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else { return frames }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            switch status {
            case .haveData:
                writeAndEmit(buffer, to: audioFile, publishLevel: false)
                frames += buffer.frameLength
            case .endOfStream, .inputRanDry:
                // The last drain can carry a short tail — emit it too.
                if buffer.frameLength > 0 {
                    writeAndEmit(buffer, to: audioFile, publishLevel: false)
                    frames += buffer.frameLength
                }
                return frames
            case .error:
                SapoLog.flux.error(
                    "Capture converter flush failed error=\(error?.localizedDescription ?? "unknown", privacy: .public)"
                )
                return frames
            @unknown default:
                return frames
            }
        }
    }
}
