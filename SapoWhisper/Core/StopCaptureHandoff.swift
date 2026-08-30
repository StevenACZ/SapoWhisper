@MainActor
enum StopCaptureHandoff {
    static func perform<Result>(
        seal: () -> Result,
        onStopped: @MainActor @Sendable () -> Void
    ) -> Result {
        let result = seal()
        onStopped()
        return result
    }
}
