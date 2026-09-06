import Foundation

public enum WhisperDecodingError: Error, Equatable, Sendable {
    case outputLimit
}

struct WhisperDecodingWindow: Equatable {
    let range: Range<Int>
    var retryDepth: Int = 0
    var usesInitialPrompt: Bool = true

    static func initial(sampleCount: Int) -> [Self] {
        guard sampleCount > 0 else { return [] }
        return stride(from: 0, to: sampleCount, by: WhisperAudioConfig.chunkLengthSamples).map { start in
            Self(range: start..<(start + min(WhisperAudioConfig.chunkLengthSamples, sampleCount - start)))
        }
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
