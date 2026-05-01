//
//  SapoLog.swift
//  SapoWhisper
//

import Foundation
import OSLog

enum SapoLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "oli.SapoWhisper"

    static let audioRoute = Logger(subsystem: subsystem, category: "AudioRoute")
    static let hotkey = Logger(subsystem: subsystem, category: "Hotkey")
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
}
