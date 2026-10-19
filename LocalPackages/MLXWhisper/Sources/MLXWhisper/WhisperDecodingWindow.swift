import Foundation

public enum WhisperDecodingError: Error, Equatable, Sendable {
    case outputLimit
}

struct WhisperDecodingWindow: Equatable {
    let range: Range<Int>
    var retryDepth: Int = 0
    var usesInitialPrompt: Bool = true

    static let frameSamples = WhisperAudioConfig.sampleRate / 50
    static let pauseFrames = 10
    static let minimumWindowSamples = 20 * WhisperAudioConfig.sampleRate

    /// Windows of at most 30 s that end at the quietest 200 ms between 20 s
    /// and 30 s, so a word is never cut by a fixed 30 s boundary.
    static func initial(samples: [Float]) -> [Self] {
        guard !samples.isEmpty else { return [] }
        let chunk = WhisperAudioConfig.chunkLengthSamples
        let frame = frameSamples
        let frameCount = samples.count / frame
        var energyPrefix = [Double](repeating: 0, count: frameCount + 1)
        samples.withUnsafeBufferPointer { buffer in
            for index in 0..<frameCount {
                var energy: Double = 0
                for sample in buffer[(index * frame)..<((index + 1) * frame)] {
                    energy += Double(sample * sample)
                }
                energyPrefix[index + 1] = energyPrefix[index] + energy
            }
        }

        var windows: [Self] = []
        var start = 0
        while samples.count - start > chunk {
            let firstFrame = (start + minimumWindowSamples + frame - 1) / frame
            let lastFrame = (start + chunk) / frame - pauseFrames
            var cut = start + chunk
            if firstFrame <= lastFrame {
                var quietest = Double.greatestFiniteMagnitude
                for candidate in firstFrame...lastFrame {
                    let energy = energyPrefix[candidate + pauseFrames] - energyPrefix[candidate]
                    if energy <= quietest {
                        quietest = energy
                        cut = (candidate + pauseFrames / 2) * frame
                    }
                }
            }
            windows.append(Self(range: start..<cut))
            start = cut
        }
        windows.append(Self(range: start..<samples.count))
        return windows
    }

    func splitAfterOutputLimit() throws -> [Self] {
        guard retryDepth < 2, range.count >= WhisperAudioConfig.sampleRate * 2 else {
            throw WhisperDecodingError.outputLimit
        }
        let midpoint = range.lowerBound + range.count / 2
        return [
            Self(range: range.lowerBound..<midpoint, retryDepth: retryDepth + 1, usesInitialPrompt: usesInitialPrompt),
            Self(range: midpoint..<range.upperBound, retryDepth: retryDepth + 1, usesInitialPrompt: usesInitialPrompt),
        ]
    }
}
