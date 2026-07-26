//
//  AudioCaptureEngine+Diagnostics.swift
//  SapoWhisper
//

import AVFoundation
import Foundation
import os

nonisolated extension AudioCaptureEngine {
    func cleanupSetupArtifacts(engine: AVAudioEngine?, recordingURL: URL?, deleteTemporaryFile: Bool) {
        deviceSentinel.end()
        if let engine {
            // Teardown races the route change that aborted the setup; a guarded
            // exception here just means the engine is already dead.
            try? AudioEngineGuard.run("cleanup-setup-teardown") {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                engine.reset()
            }
        }

        audioWriteQueue.sync {}
        audioFile = nil
        audioEngine = nil
        converter = nil
        converterOutputFormat = nil
        chunkHandler = nil

        let cleanupURL = self.recordingURL ?? recordingURL
        self.recordingURL = nil
        if let cleanupURL {
            ActiveRecordingMarker.clear(cleanupURL)
            if deleteTemporaryFile {
                deleteRecording(at: cleanupURL)
            }
        }
    }

    func resetCaptureDiagnostics(deviceUID: String) {
        captureStateLock.lock()
        inputBufferCount = 0
        writtenFrameCount = 0
        emittedChunkCount = 0
        firstInputLatencyMs = nil
        maxInputGapMs = 0
        failedWriteCount = 0
        firstWriteError = nil
        captureDeviceUID = deviceUID
        captureStateLock.unlock()
    }

    func registerInputBuffer(at timestamp: CFAbsoluteTime) -> (count: Int, gapMs: Double?) {
        captureStateLock.lock()
        let previousInputTime = lastInputBufferTime
        // Publish the timestamp under the lock (read before this point for the
        // gap). The health probe / diagnostics read it off another queue, so
        // the write must go through captureStateLock.
        lastInputBufferTime = timestamp
        inputBufferCount += 1
        let count = inputBufferCount
        let gapMs = previousInputTime > 0 ? (timestamp - previousInputTime) * 1000 : nil
        if let gapMs {
            maxInputGapMs = max(maxInputGapMs, gapMs)
        }
        if firstInputLatencyMs == nil {
            firstInputLatencyMs = (timestamp - startRecordingTime) * 1000
        }
        captureStateLock.unlock()
        return (count, gapMs)
    }

    func currentLastInputBufferTime() -> CFAbsoluteTime {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        return lastInputBufferTime
    }

    func resetLastInputBufferTime() {
        captureStateLock.lock()
        defer { captureStateLock.unlock() }
        lastInputBufferTime = 0
    }

    func registerWrittenFrames(_ frameCount: AVAudioFrameCount) {
        captureStateLock.lock()
        writtenFrameCount += AVAudioFramePosition(frameCount)
        captureStateLock.unlock()
    }

    func registerWriteFailure(_ error: Error) {
        captureStateLock.lock()
        failedWriteCount += 1
        if firstWriteError == nil {
            firstWriteError = error.localizedDescription
        }
        captureStateLock.unlock()
    }

    func registerEmittedChunk() -> Int {
        captureStateLock.lock()
        emittedChunkCount += 1
        let count = emittedChunkCount
        captureStateLock.unlock()
        return count
    }

    func setCaptureDeviceUID(_ uid: String) {
        captureStateLock.lock()
        captureDeviceUID = uid
        captureStateLock.unlock()
    }

    func currentCaptureDeviceUID() -> String {
        captureStateLock.lock()
        let uid = captureDeviceUID
        captureStateLock.unlock()
        return uid
    }

    func hasReceivedInputBuffer() -> Bool {
        captureStateLock.lock()
        let hasInput = inputBufferCount > 0
        captureStateLock.unlock()
        return hasInput
    }

    func makeCaptureDiagnostics(fileURL: URL?, referenceTime: CFAbsoluteTime) -> RecordingCaptureDiagnostics {
        captureStateLock.lock()
        let bufferCount = inputBufferCount
        let frameCount = writtenFrameCount
        let chunkCount = emittedChunkCount
        let firstLatency = firstInputLatencyMs
        let maxGap = maxInputGapMs
        let deviceUID = captureDeviceUID
        let lastBuffer = lastInputBufferTime
        let failedWrites = failedWriteCount
        let writeError = firstWriteError
        captureStateLock.unlock()

        let lastBufferAgeMs = lastBuffer > 0 ? (referenceTime - lastBuffer) * 1000 : nil
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
            fileSizeBytes: fileSizeBytes,
            failedWriteCount: failedWrites,
            firstWriteError: writeError
        )
    }

    func logFirstInputBufferIfNeeded(buffer: AVAudioPCMBuffer, inputTime: CFAbsoluteTime) {
        guard !firstInputBufferLogged else { return }
        firstInputBufferLogged = true
        let elapsedMs = Int((inputTime - startRecordingTime) * 1000)
        let captureDeviceUID = currentCaptureDeviceUID()
        let effectiveDevice =
            captureDeviceUID == AudioDevice.systemDefault.uid ? "system-default" : captureDeviceUID
        SapoLog.recording.info(
            "\(self.mode.logLabel, privacy: .public) first input buffer in \(elapsedMs, privacy: .public)ms frames=\(buffer.frameLength, privacy: .public) sampleRate=\(Int(buffer.format.sampleRate), privacy: .public) input=\(effectiveDevice, privacy: .public)"
        )
    }
}
