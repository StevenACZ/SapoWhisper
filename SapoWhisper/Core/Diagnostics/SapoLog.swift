//
//  SapoLog.swift
//  SapoWhisper
//

import Foundation
import OSLog

enum SapoLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "oli.SapoWhisper"

    static let audioRoute = Logger(subsystem: subsystem, category: "AudioRoute")
    static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
    static let hotkey = Logger(subsystem: subsystem, category: "Hotkey")
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    static let performance = Logger(subsystem: subsystem, category: "Performance")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let flux = Logger(subsystem: subsystem, category: "Flux")
    static let ai = Logger(subsystem: subsystem, category: "AI")
    static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
}

enum SapoSignpost {
    #if DEBUG
        private static let signposter = OSSignposter(subsystem: SapoLog.subsystem, category: "Signpost")
    #endif

    enum Name {
        static let hotkeyToOverlay: StaticString = "hotkey-to-overlay"
        static let transcription: StaticString = "transcription"
        static let polish: StaticString = "polish"
    }

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        #if DEBUG
            return signposter.beginInterval(name)
        #else
            return nil
        #endif
    }

    static func end(_ name: StaticString, state: OSSignpostIntervalState?) {
        #if DEBUG
            guard let state else { return }
            signposter.endInterval(name, state)
        #endif
    }
}

enum PerformanceDiagnostics {
    static func logMemorySnapshot(reason: String, force: Bool = false) {
        _ = reason
        _ = force
    }

    static func logRuntimeSnapshot(reason: String, context: String = "", force: Bool = false) {
        _ = reason
        _ = context
        _ = force
    }

    static func logDiagnosticsFileLocation() {
        // Runtime JSONL diagnostics were removed after the long-run validation pass.
    }
}
