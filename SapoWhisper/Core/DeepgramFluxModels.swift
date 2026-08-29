//
//  DeepgramFluxModels.swift
//  SapoWhisper
//

import Foundation

struct DeepgramFluxTranscriptAccumulator {
    private var turns: [Int: String] = [:]
    private var fragments: [String] = []

    mutating func update(with json: [String: Any]) {
        guard let rawTranscript = json["transcript"] as? String else { return }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }

        if let turnIndex = json["turn_index"] as? Int {
            turns[turnIndex] = transcript
            return
        }

        if fragments.last != transcript {
            fragments.append(transcript)
        }
    }

    var transcript: String {
        if !turns.isEmpty {
            return turns.keys.sorted()
                .compactMap { turns[$0] }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return
            fragments
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DeepgramFluxFinalizationCompletion: Equatable {
    case pending
    case succeeded
    case failed
}

struct DeepgramFluxFinalizationGate {
    private(set) var closeStreamStarted = false
    private(set) var receiveCompleted = false
    private var receiveCloseCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var receiveCompletedBeforeClose = false

    mutating func beginCloseStream() {
        closeStreamStarted = true
    }

    mutating func completeReceive(closeCode: URLSessionWebSocketTask.CloseCode) {
        receiveCompleted = true
        receiveCloseCode = closeCode
        receiveCompletedBeforeClose = !closeStreamStarted
    }

    var completion: DeepgramFluxFinalizationCompletion {
        guard closeStreamStarted, receiveCompleted else { return .pending }
        return !receiveCompletedBeforeClose && receiveCloseCode == .normalClosure ? .succeeded : .failed
    }

    var canFinish: Bool {
        completion == .succeeded
    }
}
