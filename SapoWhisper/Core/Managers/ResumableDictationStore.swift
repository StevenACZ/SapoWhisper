//
//  ResumableDictationStore.swift
//  SapoWhisper
//

import Foundation

/// A recently cancelled or crash-recovered take the user may prepend to
/// the next recording ("continuar dictado anterior").
nonisolated struct ResumableDictation: Sendable {
    static let lifetime: TimeInterval = 30 * 60
    let historyId: Int64
    let audioURL: URL
    let duration: TimeInterval
    let capturedAt: Date
    var offeredAt: Date? = nil
}

/// Holds the continue-previous offer plus the user's opt-in, with the
/// 30-minute expiry and audio-file-existence invalidation.
@MainActor
final class ResumableDictationStore {

    private var resumable: ResumableDictation?
    /// The user opted into the merge via the recording pill chip.
    private var requestedOffer: ResumableDictation?
    var mergeRequested = false {
        didSet { requestedOffer = mergeRequested ? validOffer : nil }
    }

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
        guard now().timeIntervalSince(resumable.offeredAt ?? resumable.capturedAt) < ResumableDictation.lifetime,
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
        let requested = requestedOffer
        mergeRequested = false
        guard let requested, fileExists(requested.audioURL.path) else { return nil }
        return requested
    }

    /// The merged take supersedes the offer — keeping it would duplicate the
    /// same audio in History.
    func clearOffer() {
        resumable = nil
        mergeRequested = false
    }

    /// A retranscribed take is resolved: continuing it would duplicate a
    /// transcript that already exists, and a later merge would delete the
    /// completed row. Returns whether the stored offer was the cleared one,
    /// so the caller can also drop a live resume chip.
    @discardableResult
    func clearOffer(forHistoryId id: Int64) -> Bool {
        guard resumable?.historyId == id || requestedOffer?.historyId == id else { return false }
        clearOffer()
        return true
    }

    /// m:ss label for the resume chip.
    static func formatResumeDuration(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
