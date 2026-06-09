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
    private static var residencyTimer: Timer?

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

    /// R3: one RSS line per day (plus launch) proves flat memory over weeks of
    /// residency without any heavier tooling.
    static func startDailyResidencyLog() {
        guard residencyTimer == nil else { return }

        logResidentMemory(reason: "launch")
        let timer = Timer(timeInterval: 86_400, repeats: true) { _ in
            logResidentMemory(reason: "daily")
        }
        timer.tolerance = 3_600
        RunLoop.main.add(timer, forMode: .common)
        residencyTimer = timer
    }

    static func logResidentMemory(reason: String) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            SapoLog.performance.warning("Resident memory query failed code=\(result, privacy: .public)")
            return
        }

        let residentMB = Int(info.phys_footprint / 1_048_576)
        SapoLog.performance.info(
            "Resident memory reason=\(reason, privacy: .public) footprintMB=\(residentMB, privacy: .public)"
        )
    }
}
