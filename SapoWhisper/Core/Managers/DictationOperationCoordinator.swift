import Foundation
import Observation

@MainActor
@Observable
final class DictationOperationCoordinator {
    struct Context {
        let sessionID: UInt64
        let historyId: Int64?
        let audioURL: URL?
        let duration: TimeInterval
        let variant: TranscriptionEngineVariant
    }

    private(set) var active: Context?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cancelEngine: (@MainActor () -> Void)?

    @discardableResult
    func run(
        _ context: Context,
        cancelEngine: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) async -> Bool {
        guard active == nil else { return false }
        let task = Task { await operation() }
        active = context
        self.task = task
        self.cancelEngine = cancelEngine
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor [weak self] in
                self?.cancel(sessionID: context.sessionID)
            }
        }
        if active?.sessionID == context.sessionID {
            active = nil
            self.task = nil
            self.cancelEngine = nil
        }
        return true
    }

    func cancel(sessionID: UInt64) {
        guard active?.sessionID == sessionID else { return }
        task?.cancel()
        let cancel = cancelEngine
        cancelEngine = nil
        cancel?()
    }
}
