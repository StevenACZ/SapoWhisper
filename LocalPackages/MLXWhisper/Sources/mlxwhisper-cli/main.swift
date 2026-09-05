//
//  main.swift
//  mlxwhisper-cli
//
//  Terminal bench/QA runner for the vendored MLX Whisper engine. XCTest-host
//  numbers are not representative for the GPU path, so engine evidence
//  (latency, fidelity, initial-prompt effect) comes from real runs here.
//
//  Usage:
//    mlxwhisper-cli <model-dir> <audio.wav> [--language es] [--prompt "term1, term2"] [--stream]
//

@preconcurrency import AVFoundation
import Foundation
import MLX
import MLXWhisper

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Decode any audio file to 16 kHz mono Float32 samples.
func loadAudioSamples(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    else {
        fail("Could not create target audio format")
    }

    let sourceFormat = file.processingFormat
    guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
        fail("Could not create audio converter for \(url.lastPathComponent)")
    }

    let sourceCapacity: AVAudioFrameCount = 65536
    guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceCapacity) else {
        fail("Could not allocate source buffer")
    }

    var samples: [Float] = []
    var reachedEnd = false
    while !reachedEnd {
        // Reading at exact EOF throws on AVAudioFile; gate on framePosition.
        if file.framePosition >= file.length {
            break
        }
        try file.read(into: sourceBuffer)
        if sourceBuffer.frameLength == 0 { break }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            fail("Could not allocate conversion buffer")
        }

        // The input block is @Sendable; a class box keeps the one-shot flag
        // mutable without capturing a local var in concurrent code.
        final class FeedState: @unchecked Sendable { var fed = false }
        let feedState = FeedState()
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if feedState.fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            feedState.fed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .error {
            fail("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown")")
        }
        if let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
        }
        reachedEnd = status == .endOfStream
    }
    return samples
}

// MARK: - Argument parsing

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "download" {
    guard arguments.count == 4,
        arguments[2].range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil
    else { fail("Usage: mlxwhisper-cli download <repo> <pinned-revision> <model-root>") }
    do {
        let repo = arguments[1]
        let root = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let destination = WhisperModelDownloader.modelDirectory(repo: repo, root: root)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            fail("Download requires a new model directory; an existing snapshot cannot prove the requested revision")
        }
        _ = try await WhisperModelDownloader.download(repo: repo, revision: arguments[2], root: root)
        guard WhisperModelDownloader.isDownloaded(repo: repo, root: root) else {
            fail("Model download did not produce a complete snapshot")
        }
        print("model download complete bytes=\(WhisperModelDownloader.sizeOnDisk(repo: repo, root: root))")
        exit(0)
    } catch {
        let failure = error as NSError
        fail("Model download failed: \(failure.domain)/\(failure.code)")
    }
}
guard arguments.count >= 2 else {
    fail("Usage: mlxwhisper-cli <model-dir> <audio.wav> [--language es] [--prompt \"...\"] [--stream]")
}
let modelDir = URL(fileURLWithPath: arguments.removeFirst())
let audioURL = URL(fileURLWithPath: arguments.removeFirst())

var language: String? = nil
var initialPrompt: String? = nil
var stream = false
while !arguments.isEmpty {
    let flag = arguments.removeFirst()
    switch flag {
    case "--language":
        guard !arguments.isEmpty else { fail("--language needs a value") }
        language = arguments.removeFirst()
    case "--prompt":
        guard !arguments.isEmpty else { fail("--prompt needs a value") }
        initialPrompt = arguments.removeFirst()
    case "--stream":
        stream = true
    default:
        fail("Unknown flag: \(flag)")
    }
}

// MARK: - Run

let samples: [Float]
do {
    samples = try loadAudioSamples(url: audioURL)
} catch {
    fail("Could not read audio: \(error.localizedDescription)")
}
let durationSeconds = Double(samples.count) / 16000.0
print("audio: \(audioURL.lastPathComponent)  duration=\(String(format: "%.1f", durationSeconds))s")

// Top-level await keeps the main thread free: HubClient's progress handler
// is @MainActor, so blocking main (e.g. a semaphore) deadlocks the download.
do {
    let loadStart = Date()
    let model = try await WhisperModel.fromDirectory(modelDir)
    let loadElapsed = Date().timeIntervalSince(loadStart)
    print("model loaded in \(String(format: "%.2f", loadElapsed))s")

    let parameters = STTGenerateParameters(
        maxTokens: model.config.maxTargetPositions - 16,
        temperature: 0.0,
        language: language,
        initialPrompt: initialPrompt
    )

    let audio = MLXArray(samples)
    let start = Date()
    let output: STTOutput
    if stream {
        var finalOutput: STTOutput?
        for try await event in model.generateStream(audio: audio, generationParameters: parameters) {
            switch event {
            case .token(let delta):
                print(delta, terminator: "")
                FileHandle.standardOutput.synchronizeFile()
            case .result(let result):
                finalOutput = result
            }
        }
        print("")
        guard let result = finalOutput else { fail("Stream ended without a result") }
        output = result
    } else {
        output = try model.generateCancellable(audio: audio, generationParameters: parameters)
    }
    let elapsed = Date().timeIntervalSince(start)

    print("---")
    print(output.text)
    print("---")
    let rtf = durationSeconds > 0 ? elapsed / durationSeconds : 0
    print(
        String(
            format: "transcribe=%.2fs  rtf=%.3f  tokens=%d  peakMem=%.2fGB",
            elapsed, rtf, output.generationTokens, output.peakMemoryUsage))
    print("decoder retries: \(output.decodingRetries)")
    if let detected = output.language {
        print("language: \(detected)")
    }
    if initialPrompt != nil {
        print("initial prompt: \(output.promptTokens) prompt tokens (includes <|startofprev|> prefix)")
    }
} catch {
    FileHandle.standardError.write(Data(("error: \(error.localizedDescription)\n").utf8))
    exit(1)
}
