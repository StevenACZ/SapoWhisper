//
//  StreamingAudioCapture+Diagnostics.swift
//  SapoWhisper
//

import AVFoundation
import Foundation
import os

nonisolated extension StreamingAudioCapture {
    func cleanupSetupArtifacts(engine: AVAudioEngine?, recordingURL: URL?, deleteTemporaryFile: Bool) {
        setCaptureActive(false)
        deviceSentinel.end()
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine?.reset()
        audioWriteQueue.sync {}
        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil
        chunkHandler = nil
        if deleteTemporaryFile, let url = recordingURL ?? self.recordingURL {
            deleteRecording(at: url)
        }
        self.recordingURL = nil
    }

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    func resetPublishedState() {
        recordingDuration = 0
        startTime = nil
        accumulatedDuration = 0
        audioLevel = 0
        smoothedAudioLevel = 0
        startRecordingTime = 0
        firstInputBufferLogged = false
        lastInputBufferTime = 0
    }

    func resetCaptureDiagnostics(deviceUID: String) {
        os_unfair_lock_lock(&captureStateLock)
        inputBufferCount = 0
        writtenFrameCount = 0
        emittedChunkCount = 0
        firstInputLatencyMs = nil
        maxInputGapMs = 0
        captureDeviceUID = deviceUID
        os_unfair_lock_unlock(&captureStateLock)
    }

    func registerInputBuffer(at timestamp: CFAbsoluteTime) -> (count: Int, gapMs: Double?) {
        os_unfair_lock_lock(&captureStateLock)
        let previousInputTime = lastInputBufferTime
        inputBufferCount += 1
        let count = inputBufferCount
        let gapMs = previousInputTime > 0 ? (timestamp - previousInputTime) * 1000 : nil
        if let gapMs {
            maxInputGapMs = max(maxInputGapMs, gapMs)
        }
        if firstInputLatencyMs == nil {
            firstInputLatencyMs = (timestamp - startRecordingTime) * 1000
        }
        os_unfair_lock_unlock(&captureStateLock)
        return (count, gapMs)
    }

    func registerWrittenFrames(_ frameCount: AVAudioFrameCount) {
        os_unfair_lock_lock(&captureStateLock)
        writtenFrameCount += AVAudioFramePosition(frameCount)
        os_unfair_lock_unlock(&captureStateLock)
    }

    func registerEmittedChunk() -> Int {
        os_unfair_lock_lock(&captureStateLock)
        emittedChunkCount += 1
        let count = emittedChunkCount
        os_unfair_lock_unlock(&captureStateLock)
        return count
    }

    func setCaptureActive(_ active: Bool) {
        os_unfair_lock_lock(&captureStateLock)
        captureActive = active
        os_unfair_lock_unlock(&captureStateLock)
    }

    func isCaptureActiveFlag() -> Bool {
        os_unfair_lock_lock(&captureStateLock)
        let active = captureActive
        os_unfair_lock_unlock(&captureStateLock)
        return active
    }

    func setCaptureDeviceUID(_ uid: String) {
        os_unfair_lock_lock(&captureStateLock)
        captureDeviceUID = uid
        os_unfair_lock_unlock(&captureStateLock)
    }

    func currentCaptureDeviceUID() -> String {
        os_unfair_lock_lock(&captureStateLock)
        let uid = captureDeviceUID
        os_unfair_lock_unlock(&captureStateLock)
        return uid
    }

    func hasReceivedInputBuffer() -> Bool {
        os_unfair_lock_lock(&captureStateLock)
        let hasInput = inputBufferCount > 0
        os_unfair_lock_unlock(&captureStateLock)
        return hasInput
    }

    func makeCaptureDiagnostics(fileURL: URL?, referenceTime: CFAbsoluteTime) -> RecordingCaptureDiagnostics {
        os_unfair_lock_lock(&captureStateLock)
        let bufferCount = inputBufferCount
        let frameCount = writtenFrameCount
        let chunkCount = emittedChunkCount
        let firstLatency = firstInputLatencyMs
        let maxGap = maxInputGapMs
        let deviceUID = captureDeviceUID
        os_unfair_lock_unlock(&captureStateLock)

        let lastBufferAgeMs = lastInputBufferTime > 0 ? (referenceTime - lastInputBufferTime) * 1000 : nil
        let fileSizeBytes: Int
        if let fileURL,
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue
        {
            fileSizeBytes = size
        } else {
            fileSizeBytes = 0
        }

        return RecordingCaptureDiagnostics(
            selectedDeviceUID: deviceUID,
            inputBufferCount: bufferCount,
            writtenFrameCount: frameCount,
            emittedChunkCount: chunkCount,
            firstInputLatencyMs: firstLatency,
            lastBufferAgeMs: lastBufferAgeMs,
            maxInputGapMs: maxGap,
            fileSizeBytes: fileSizeBytes
        )
    }

    func logFirstInputBufferIfNeeded(buffer: AVAudioPCMBuffer, inputTime: CFAbsoluteTime) {
        guard !firstInputBufferLogged else { return }
        firstInputBufferLogged = true
        let elapsedMs = Int((inputTime - startRecordingTime) * 1000)
        SapoLog.recording.info(
            "Flux first input buffer in \(elapsedMs, privacy: .public)ms frames=\(buffer.frameLength, privacy: .public)"
        )
    }
}
