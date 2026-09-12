import AudioToolbox
import Foundation

nonisolated final class CaptureInputFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?
    private var notifying = false
    private var failure: OSStatus?

    var firstFailure: OSStatus? { lock.withLock { failure } }

    func beginInput() -> UUID {
        lock.withLock {
            let next = UUID()
            token = next
            notifying = true
            return next
        }
    }

    func record(_ status: OSStatus, for candidate: UUID) {
        lock.withLock {
            guard status != noErr, token == candidate, failure == nil else { return }
            failure = status
        }
    }

    func shouldNotify(for candidate: UUID) -> Bool {
        lock.withLock { notifying && token == candidate }
    }

    func stopNotifying() {
        lock.withLock { notifying = false }
    }
}
