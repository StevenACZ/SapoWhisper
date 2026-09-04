//
//  AudioFileMerger.swift
//  SapoWhisper
//

import AVFoundation
import Foundation
import os

/// Concatenates two WAVs into one — the "continue previous dictation" merge.
/// The output uses the second (current) file's format; the first file is
/// converted when its format differs (upload quality or device sample rate
/// may have changed between takes).
nonisolated enum AudioFileMerger {

    enum MergeError: LocalizedError {
        case unreadableInput
        case converterCreationFailed

        var errorDescription: String? {
            switch self {
            case .unreadableInput:
                return "No se pudo leer el audio anterior para unirlo"
            case .converterCreationFailed:
                return "No se pudo convertir el audio anterior para unirlo"
            }
        }
    }

    private static let chunkFrameCapacity: AVAudioFrameCount = 8192

    /// Appends `second` after `first` into a fresh temp WAV and returns its URL.
    /// Inputs are left untouched.
    static func merge(first firstURL: URL, second secondURL: URL) throws -> URL {
        let firstFile = try AVAudioFile(forReading: firstURL)
        let secondFile = try AVAudioFile(forReading: secondURL)

        let outputURL = TemporaryAudioStorage.makeWAVURL(prefix: "recording")
        let targetFormat = secondFile.processingFormat
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: secondFile.fileFormat.settings,
            commonFormat: targetFormat.commonFormat,
            interleaved: targetFormat.isInterleaved
        )

        do {
            try append(firstFile, to: outputFile, targetFormat: targetFormat)
            try append(secondFile, to: outputFile, targetFormat: targetFormat)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        SapoLog.recording.info(
            "Merged previous dictation framesA=\(firstFile.length, privacy: .public) framesB=\(secondFile.length, privacy: .public)"
        )
        return outputURL
    }

    private static func append(_ input: AVAudioFile, to output: AVAudioFile, targetFormat: AVAudioFormat) throws {
        let inputFormat = input.processingFormat
        let needsConversion =
            inputFormat.sampleRate != targetFormat.sampleRate
            || inputFormat.channelCount != targetFormat.channelCount
            || inputFormat.commonFormat != targetFormat.commonFormat
            || inputFormat.isInterleaved != targetFormat.isInterleaved

        if !needsConversion {
            // AVAudioFile.read(into:) throws (a bare "nilError") when called
            // at exact EOF instead of returning an empty buffer, so the loop
            // must stop on framePosition, not on a zero-length read.
            while input.framePosition < input.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrameCapacity) else {
                    throw MergeError.unreadableInput
                }
                try input.read(into: buffer)
                guard buffer.frameLength > 0 else { return }
                try output.write(from: buffer)
            }
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MergeError.converterCreationFailed
        }

        let source = AudioConverterInputSource(file: input, maximumFrames: chunkFrameCapacity)
        let outputCapacity = AVAudioFrameCount(
            ceil(Double(chunkFrameCapacity) * targetFormat.sampleRate / inputFormat.sampleRate) + 64
        )

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw MergeError.unreadableInput
            }

            let status = converter.convert(to: outputBuffer, error: nil, withInputFrom: source.provide)
            if let readError = source.readError { throw readError }

            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return
            case .error:
                throw MergeError.converterCreationFailed
            @unknown default:
                return
            }
        }
    }
}
