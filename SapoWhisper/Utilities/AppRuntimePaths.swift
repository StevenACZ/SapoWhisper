import Foundation

nonisolated enum AppRuntimePaths {
    private static let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("SapoWhisperTests-\(UUID().uuidString)", isDirectory: true)

    static var isIsolated: Bool { UIPreviewMode.skipsConsentPrompts }

    static var applicationSupport: URL {
        if UIPreviewMode.skipsConsentPrompts { return testRoot.appendingPathComponent("support", isDirectory: true) }
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SapoWhisper", isDirectory: true)
    }

    static var temporaryAudio: URL {
        if UIPreviewMode.skipsConsentPrompts { return testRoot.appendingPathComponent("audio-temp", isDirectory: true) }
        let base =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("oli.SapoWhisper", isDirectory: true)
            .appendingPathComponent("audio-temp", isDirectory: true)
    }
}
