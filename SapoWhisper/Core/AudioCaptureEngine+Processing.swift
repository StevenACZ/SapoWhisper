//
//  AudioCaptureEngine+Processing.swift
//  SapoWhisper
//

// AVFAudio's converter/tap callbacks predate Sendable annotations; buffers are
// handed off queue-to-queue under the class's own synchronization.
@preconcurrency import AVFAudio
import AVFoundation
import Foundation
import os

nonisolated extension AudioCaptureEngine {
    /// Procesa el buffer de audio: gain → conversión → chunk emission (streaming) → escritura
    func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let audioFile, let outputFormat = converterOutputFormat else { return }
        let inputTime = CFAbsoluteTimeGetCurrent()
        let bufferStats = registerInputBuffer(at: inputTime)
        if let gapMs = bufferStats.gapMs, gapMs > 250 {
            SapoLog.recording.warning(
                "\(self.mode.logLabel, privacy: .public) input gap detected gap=\(Int(gapMs), privacy: .public)ms buffer=\(bufferStats.count, privacy: .public)"
            )
        }
        if bufferStats.count % 100 == 0 {
            SapoLog.recording.info(
                "\(self.mode.logLabel, privacy: .public) input progress buffers=\(bufferStats.count, privacy: .public) frames=\(self.writtenFrameCount, privacy: .public)"
            )
        }
        logFirstInputBufferIfNeeded(buffer: buffer, inputTime: inputTime)

        // Gain runs on the raw tap buffer BEFORE conversion: amplifying the
        // already-quantized int16 output hard-clipped at high gain settings
        // and threw away the float headroom the limiter needs.
        applyGainIfNeeded(to: buffer)

        converterLock.lock()
        defer { converterLock.unlock() }

        // Lazy converter creation from actual buffer format (avoids stale format cache after device switch).
        // A2: rebuilt when the tap format changes mid-capture (route recovery rebinds the input).
        if converter == nil || converter?.inputFormat != buffer.format {
            let inputFmt = buffer.format
            if converter != nil {
                SapoLog.recording.info(
                    "\(self.mode.logLabel, privacy: .public) tap format changed, rebuilding converter inHz=\(Int(inputFmt.sampleRate), privacy: .public)"
                )
            } else {
                SapoLog.recording.info(
                    "\(self.mode.logLabel, privacy: .public) creating converter inHz=\(Int(inputFmt.sampleRate), privacy: .public) outHz=\(Int(outputFormat.sampleRate), privacy: .public)"
                )
            }
            converter = AVAudioConverter(from: inputFmt, to: outputFormat)
            if let converter {
                // Mastering-grade sample rate conversion: the default SRC's
                // anti-aliasing is mediocre for the 48k→16k hop; harmless when
                // no rate conversion happens.
                converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
                converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            } else {
                SapoLog.recording.error(
                    "\(self.mode.logLabel, privacy: .public) converter creation failed inHz=\(Int(inputFmt.sampleRate), privacy: .public) outHz=\(Int(outputFormat.sampleRate), privacy: .public)"
                )
            }
        }
        guard let converter else { return }

        let frameCapacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        var didPublishLevel = false
        let input = AudioConverterInputSource(buffer: buffer)

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else { return }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: input.provide)

            switch status {
            case .haveData:
                writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                didPublishLevel = true
            case .inputRanDry, .endOfStream:
                // The converter can hand back a short tail together with
                // inputRanDry — write it instead of dropping those frames.
                if convertedBuffer.frameLength > 0 {
                    writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                }
                return
            case .error:
                let detail =
                    error.map { LogSanitizer.errorDiagnostic($0, state: "audio-convert") }
                    ?? "state=audio-convert domain=none code=0"
                SapoLog.recording.error(
                    "\(self.mode.logLabel, privacy: .public) audio conversion failed \(detail, privacy: .public)"
                )
                return
            @unknown default:
                return
            }
        }
    }

    func writeConvertedBuffer(_ convertedBuffer: AVAudioPCMBuffer, to audioFile: AVAudioFile, publishLevel: Bool) {
        guard convertedBuffer.frameLength > 0 else { return }

        // Gain was already applied to the tap buffer before conversion, so the
        // published level below still reflects the post-gain signal.
        if publishLevel {
            publishAudioLevel(from: convertedBuffer)
        }

        // Emit to the streaming engine first: the WAV is the local backup and
        // a slow (or failing) disk must never delay or drop live chunks.
        if let chunkHandler, let data = pcmData(from: convertedBuffer) {
            let chunkCount = registerEmittedChunk()
            if chunkCount % 100 == 0 {
                SapoLog.flux.info("Flux local audio chunks emitted count=\(chunkCount, privacy: .public)")
            }
            chunkHandler(data)
        }

        // A1: the disk write runs on a dedicated serial queue; the converted
        // buffer is owned by this call, so handing it off is safe. The stop
        // path drains this queue before closing the file.
        audioWriteQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.writeBuffer(convertedBuffer, audioFile)
                self.registerWrittenFrames(convertedBuffer.frameLength)
            } catch {
                self.registerWriteFailure(error)
                let detail = LogSanitizer.errorDiagnostic(error, state: "audio-write")
                SapoLog.recording.error(
                    "\(self.mode.logLabel, privacy: .public) audio buffer write failed \(detail, privacy: .public)"
                )
            }
        }
    }

    func pcmData(from buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.int16ChannelData else { return nil }
        return Data(bytes: channelData[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Calculates and publishes capture level from the same buffer tap used for writing.
    /// This avoids spinning up a second AVAudioEngine only for visualization.
    func publishAudioLevel(from buffer: AVAudioPCMBuffer) {
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        var sum: Float = 0

        if let channelData = buffer.floatChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            for sample in samples {
                sum += sample * sample
            }
        } else if let channelData = buffer.int16ChannelData {
            let samples = UnsafeBufferPointer(start: channelData[0], count: frameLength)
            for sample in samples {
                let normalized = Float(sample) / Float(Int16.max)
                sum += normalized * normalized
            }
        } else {
            return
        }

        let rms = sqrt(sum / Float(frameLength))
        let avgPower = 20 * log10(max(rms, 0.0001))
        let normalized = max(0, min(1, (avgPower + 60) / 60))

        // Asymmetric smoothing: rises track the voice almost immediately
        // (buffers arrive ~10x/s, so a symmetric 0.3 blend swallowed word
        // onsets and sharp sounds), while falls keep the slower blend so the
        // meter decays instead of flickering.
        if normalized > smoothedAudioLevel {
            smoothedAudioLevel = (smoothedAudioLevel * 0.25) + (normalized * 0.75)
        } else {
            smoothedAudioLevel = (smoothedAudioLevel * 0.7) + (normalized * 0.3)
        }

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

    /// Flushes any delayed samples still buffered inside AVAudioConverter.
    @discardableResult
    func flushRemainingConvertedAudio() -> AVAudioFrameCount {
        guard let converter, let outputFormat = converterOutputFormat, let audioFile else { return 0 }
        converterLock.lock()
        defer { converterLock.unlock() }

        var frames: AVAudioFrameCount = 0
        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                return frames
            }

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }

            switch status {
            case .haveData:
                writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: false)
                frames += convertedBuffer.frameLength
            case .endOfStream, .inputRanDry:
                // The last drain can carry a short tail — write it too.
                if convertedBuffer.frameLength > 0 {
                    writeConvertedBuffer(convertedBuffer, to: audioFile, publishLevel: false)
                    frames += convertedBuffer.frameLength
                }
                return frames
            case .error:
                let detail =
                    error.map { LogSanitizer.errorDiagnostic($0, state: "converter-flush") }
                    ?? "state=converter-flush domain=none code=0"
                SapoLog.recording.error(
                    "\(self.mode.logLabel, privacy: .public) converter flush failed \(detail, privacy: .public)"
                )
                return frames
            @unknown default:
                return frames
            }
        }
    }
}
