//
//  EngineFailoverPolicy.swift
//  SapoWhisper
//

import Foundation

/// Short-lived memory of a provider that just proved unreachable.
///
/// It exists so a dead engine is paid for ONCE: the next dictation starts on
/// the backup instead of opening the mic against a host that is known to be
/// down. The TTL is what lets the primary come back on its own — after it the
/// engine is tried again, and one success clears the entry immediately.
struct EngineReachabilityLog {
    /// Long enough that a dictation burst rides the backup without re-probing
    /// a dead host, short enough that a server coming back is picked up on the
    /// next take rather than after a restart.
    static let unreachableTTL: TimeInterval = 90

    private var unreachableSince: [TranscriptionEngine: Date] = [:]

    mutating func markUnreachable(_ engine: TranscriptionEngine, at now: Date = Date()) {
        unreachableSince[engine] = now
    }

    mutating func markReachable(_ engine: TranscriptionEngine) {
        unreachableSince.removeValue(forKey: engine)
    }

    func isUnreachable(
        _ engine: TranscriptionEngine, at now: Date = Date(), ignoringRecentFailures: Bool = false
    ) -> Bool {
        guard !ignoringRecentFailures else { return false }
        guard let since = unreachableSince[engine] else { return false }
        return now.timeIntervalSince(since) < Self.unreachableTTL
    }
}

/// Decides which engine variant runs a dictation and whether a failed one may
/// be rescued by the configured backup.
///
/// Pure by design: every input is a plain value, so the failover behaviour is
/// testable without a live engine, a server, or a clock.
enum EngineFailoverPolicy {

    static let rescuableKinds: Set<TranscriptionFailure.Kind> = [
        .network, .timedOut, .serverError, .modelOutputLimit,
    ]

    static func shouldRememberAsUnreachable(_ failure: TranscriptionFailure) -> Bool {
        [.network, .timedOut, .serverError].contains(failure.kind)
    }

    static func isRescuable(_ failure: TranscriptionFailure) -> Bool {
        rescuableKinds.contains(failure.kind)
    }

    /// What is known about one engine at the moment a dictation starts.
    struct Availability: Equatable {
        /// Configured and able to transcribe: model present, key present, and
        /// the network it needs is up.
        let isUsable: Bool
        /// A probe or a recent failure proved the host is down.
        let isKnownUnreachable: Bool

        var isHealthy: Bool { isUsable && !isKnownUnreachable }

        static let healthy = Availability(isUsable: true, isKnownUnreachable: false)
        static let unusable = Availability(isUsable: false, isKnownUnreachable: false)
        static let unreachable = Availability(isUsable: true, isKnownUnreachable: true)
    }

    enum Reason: String {
        case primaryNotReady = "primary_not_ready"
        case primaryUnreachable = "primary_unreachable"
    }

    enum Decision: Equatable {
        case primary
        case backup(reason: Reason)
        case blocked

        var usesBackup: Bool {
            if case .backup = self { return true }
            return false
        }
    }

    /// A healthy primary always wins. Otherwise a healthy backup takes the
    /// dictation. With no usable backup an unreachable-but-configured primary
    /// is still attempted — the probe may be stale and failing loudly beats
    /// refusing to record.
    static func decision(primary: Availability, backup: Availability?) -> Decision {
        if primary.isHealthy { return .primary }

        guard let backup, backup.isHealthy else {
            return primary.isUsable ? .primary : .blocked
        }
        return .backup(reason: primary.isUsable ? .primaryUnreachable : .primaryNotReady)
    }
}
