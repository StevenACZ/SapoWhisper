import Foundation

@MainActor
struct StreamingCapturePreparation {
    let capture: AudioCaptureResult?
    let pending: DictationHistoryPersister.PendingOutcome?

    var audioURL: URL? {
        pending?.audioURL ?? (capture?.diagnostics.receivedInput == true ? capture?.audioURL : nil)
    }

    var historyTarget: HistoryPersistenceTarget {
        pending.map { .finalizePending(historyId: $0.historyId) } ?? .insertNew
    }

    static func prepare(
        session: any StreamingDictationSession,
        persister: DictationHistoryPersister,
        variant: TranscriptionEngineVariant,
        engineName: String,
        language: String,
        onStopped: @escaping @MainActor @Sendable () -> Void
    ) -> Self {
        let capture = StopCaptureHandoff.perform(seal: { session.sealCapture() }, onStopped: onStopped)
        let pending = capture.flatMap { result in
            result.diagnostics.receivedInput
                ? persister.persistPending(
                    audioURL: result.audioURL, engine: variant.engine, engineName: engineName,
                    language: language, duration: result.duration, preserveSource: true
                ) : nil
        }
        return Self(capture: capture, pending: pending)
    }
}
