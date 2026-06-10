//
//  StreamingAudioCapture+Processing.swift
//  SapoWhisper
//

import AVFoundation
import Foundation
import os

extension StreamingAudioCapture {
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
        lastInputBufferTime = inputTime
        logFirstInputBufferIfNeeded(buffer: buffer, inputTime: inputTime)

        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }

        // A2: rebuilt when the tap format changes mid-capture (route recovery rebinds the input).
        if converter == nil || converter?.inputFormat != buffer.format {
            if converter != nil {
                SapoLog.recording.info(
                    "Streaming tap format changed, rebuilding converter inHz=\(Int(buffer.format.sampleRate), privacy: .public)"
                )
            }
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }

        let capacity = max(
            AVAudioFrameCount(1024),
            AVAudioFrameCount(ceil(Double(buffer.frameLength) * outputFormat.sampleRate / buffer.format.sampleRate))
        )
        var didPublishLevel = false
        var inputConsumed = false

        while true {
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            switch status {
            case .haveData:
                writeAndEmit(convertedBuffer, to: audioFile, publishLevel: !didPublishLevel)
                didPublishLevel = true
            case .inputRanDry, .endOfStream:
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
        applyGainIfNeeded(to: buffer)
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

    func applyGainIfNeeded(to buffer: AVAudioPCMBuffer) {
        guard activeGain != 1, let channelData = buffer.int16ChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let maxSample = Float(Int16.max)
        let minSample = Float(Int16.min)

        for index in 0..<frameCount {
            let amplified = Float(channelData[0][index]) * activeGain
            channelData[0][index] = Int16(max(minSample, min(maxSample, amplified)))
        }
    }

    func flushRemainingConvertedAudio() -> AVAudioFrameCount {
        guard let converter, let outputFormat = converterOutputFormat, let audioFile else { return 0 }
        os_unfair_lock_lock(&converterLock)
        defer { os_unfair_lock_unlock(&converterLock) }

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
