//
//  DeepgramFluxModels.swift
//  SapoWhisper
//

import Foundation

struct DeepgramFluxTranscriptAccumulator {
    private var turns: [Int: String] = [:]
    private var fragments: [String] = []
    private(set) var latestAudioWindowEnd: Double?
    private(set) var latestEvent: String?
    private(set) var latestUpdateApplied = false

    mutating func update(with json: [String: Any]) {
        let event = json["event"] as? String
        latestEvent = event
        latestUpdateApplied = false
        latestAudioWindowEnd = nil
        if let windowEnd = (json["audio_window_end"] as? NSNumber)?.doubleValue,
            windowEnd.isFinite, windowEnd >= 0
        {
            latestAudioWindowEnd = windowEnd
        }
        guard let rawTranscript = json["transcript"] as? String else { return }
        let transcript = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)

        if let turnIndex = json["turn_index"] as? Int {
            if transcript.isEmpty {
                turns.removeValue(forKey: turnIndex)
            } else {
                turns[turnIndex] = transcript
            }
            latestUpdateApplied = event == "Update"
            return
        }

        if event == "Update" {
            latestUpdateApplied = true
            if transcript.isEmpty {
                fragments.removeAll()
                return
            }
        }

        guard !transcript.isEmpty else { return }
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

    func coversAudio(through minimumWindowEnd: Double) -> Bool {
        guard let latestAudioWindowEnd else { return false }
        return latestAudioWindowEnd >= minimumWindowEnd
    }
}

enum DeepgramFluxFinalizationCompletion: Equatable {
    case pending
    case succeeded
    case failed
}

struct DeepgramFluxFinalizationGate {
    private(set) var closeStreamStarted = false
    private(set) var closeStreamSendConfirmed = false
    private(set) var receiveCompleted = false
    private var receiveCloseCode: URLSessionWebSocketTask.CloseCode = .invalid
    private var receiveCompletedBeforeClose = false
    private var acceptedPeerClose = false
    private(set) var receivedTurnInfoAfterCloseStream = false
    private(set) var receivedUpdateAfterCloseStream = false
    private(set) var preCloseUpdateConfirmed = false
    private var latestTurnInfoConfirmed = false

    mutating func beginCloseStream(preCloseUpdateConfirmed: Bool = false) {
        closeStreamStarted = true
        self.preCloseUpdateConfirmed = preCloseUpdateConfirmed
    }

    mutating func confirmCloseStreamSent() {
        if closeStreamStarted {
            closeStreamSendConfirmed = true
        }
    }

    mutating func recordTurnInfo(isUpdate: Bool) {
        if closeStreamStarted {
            receivedTurnInfoAfterCloseStream = true
            receivedUpdateAfterCloseStream = receivedUpdateAfterCloseStream || isUpdate
        }
    }

    mutating func completeReceive(
        closeCode: URLSessionWebSocketTask.CloseCode,
        acceptedPeerClose: Bool = false,
        latestTurnInfoIsUpdate: Bool = false
    ) {
        receiveCompleted = true
        receiveCloseCode = closeCode
        receiveCompletedBeforeClose = !closeStreamStarted
        self.acceptedPeerClose = acceptedPeerClose
        latestTurnInfoConfirmed = latestTurnInfoIsUpdate
    }

    var completion: DeepgramFluxFinalizationCompletion {
        guard closeStreamStarted, closeStreamSendConfirmed, receiveCompleted else {
            return .pending
        }
        return !receiveCompletedBeforeClose
            && (receivedUpdateAfterCloseStream || preCloseUpdateConfirmed)
            && latestTurnInfoConfirmed
            && (receiveCloseCode == .normalClosure || acceptedPeerClose)
            ? .succeeded : .failed
    }

    var canFinish: Bool {
        completion == .succeeded
    }
}
