//
//  ResumableDictationStore.swift
//  SapoWhisper
//

import Foundation

/// A recently cancelled or crash-recovered take the user may prepend to
/// the next recording ("continuar dictado anterior").
struct ResumableDictation {
    let historyId: Int64
    let audioURL: URL
    let duration: TimeInterval
    let capturedAt: Date
}

/// Holds the continue-previous offer plus the user's opt-in, with the
/// 30-minute expiry and audio-file-existence invalidation.
@MainActor
final class ResumableDictationStore {

    /// Offers older than this are stale — a new dictation is a new thought.
    private static let window: TimeInterval = 30 * 60

    private var resumable: ResumableDictation?
    /// The user opted into the merge via the recording pill chip.
    var mergeRequested = false

    private let now: () -> Date
    private let fileExists: (String) -> Bool

    init(
        now: @escaping () -> Date = Date.init,
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.now = now
        self.fileExists = fileExists
    }

    /// Entry point for new offers: an aborted capture, or the launch-time
    /// orphan recovery adopting a crashed take.
    func offer(_ resumable: ResumableDictation) {
        self.resumable = resumable
    }

    /// The current offer, or nil when expired / audio gone.
    var validOffer: ResumableDictation? {
        guard let resumable else { return nil }
        guard now().timeIntervalSince(resumable.capturedAt) < Self.window,
            fileExists(resumable.audioURL.path)
        else {
            self.resumable = nil
            return nil
        }
        return resumable
    }

    /// Stop-path takeout: the offer when the user opted in, always dropping
    /// the opt-in flag (each recording opts in anew).
    func consumeRequestedMerge() -> ResumableDictation? {
        let requested = mergeRequested ? validOffer : nil
        mergeRequested = false
        return requested
    }

    /// The merged take supersedes the offer — keeping it would duplicate the
    /// same audio in History.
    func clearOffer() {
        resumable = nil
    }

    /// A retranscribed take is resolved: continuing it would duplicate a
    /// transcript that already exists, and a later merge would delete the
    /// completed row.
    func clearOffer(forHistoryId id: Int64) {
        guard resumable?.historyId == id else { return }
        resumable = nil
    }

    /// m:ss label for the resume chip.
    static func formatResumeDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
