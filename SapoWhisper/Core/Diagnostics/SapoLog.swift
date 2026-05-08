//
//  SapoLog.swift
//  SapoWhisper
//

import AppKit
import Darwin
import Foundation
import OSLog

enum SapoLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "oli.SapoWhisper"

    static let audioRoute = Logger(subsystem: subsystem, category: "AudioRoute")
    static let menuBar = Logger(subsystem: subsystem, category: "MenuBar")
    static let hotkey = Logger(subsystem: subsystem, category: "Hotkey")
    static let overlay = Logger(subsystem: subsystem, category: "Overlay")
    static let performance = Logger(subsystem: subsystem, category: "Performance")
    static let recording = Logger(subsystem: subsystem, category: "Recording")
    static let settings = Logger(subsystem: subsystem, category: "Settings")
    static let flux = Logger(subsystem: subsystem, category: "Flux")
}

enum PerformanceDiagnostics {
    private struct MemorySnapshot {
        let footprintMB: Int
        let residentMB: Int
    }

    private static let launchTime = CFAbsoluteTimeGetCurrent()
    private static var lastMemorySnapshotTime: CFAbsoluteTime = 0
    private static var lastRuntimeSnapshotTime: CFAbsoluteTime = 0
    private static let minimumSnapshotInterval: TimeInterval = 15

    static func logMemorySnapshot(reason: String, force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastMemorySnapshotTime >= minimumSnapshotInterval else { return }
        lastMemorySnapshotTime = now

        guard let memory = currentMemorySnapshot() else {
            SapoLog.performance.warning("Memory snapshot failed reason=\(reason, privacy: .public)")
            return
        }

        SapoLog.performance.info(
            "Memory snapshot reason=\(reason, privacy: .public) footprint=\(memory.footprintMB, privacy: .public)MB resident=\(memory.residentMB, privacy: .public)MB"
        )
        DiagnosticsStore.append([
            "event": "memory",
            "reason": reason,
            "uptimeSeconds": uptimeSeconds(),
            "footprintMB": memory.footprintMB,
            "residentMB": memory.residentMB,
        ])
    }

    static func logRuntimeSnapshot(reason: String, context: String = "", force: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async {
                logRuntimeSnapshot(reason: reason, context: context, force: force)
            }
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - lastRuntimeSnapshotTime >= minimumSnapshotInterval else { return }
        lastRuntimeSnapshotTime = now

        let memory = currentMemorySnapshot()
        let uptime = uptimeSeconds()
        let screens = screenSummary()
        let frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown"

        SapoLog.performance.info(
            "Runtime snapshot reason=\(reason, privacy: .public) uptime=\(uptime, privacy: .public)s footprint=\(memory?.footprintMB ?? -1, privacy: .public)MB resident=\(memory?.residentMB ?? -1, privacy: .public)MB frontmost=\(frontmostApp, privacy: .public) screens=\(screens, privacy: .public) context=\(context, privacy: .public)"
        )

        DiagnosticsStore.append([
            "event": "runtime",
            "reason": reason,
            "uptimeSeconds": uptime,
            "footprintMB": memory?.footprintMB ?? -1,
            "residentMB": memory?.residentMB ?? -1,
            "frontmostApp": frontmostApp,
            "screens": screens,
            "context": context,
        ])
    }

    static func logDiagnosticsFileLocation() {
        guard let url = DiagnosticsStore.fileURL else { return }
        SapoLog.performance.info("Diagnostics file path=\(url.path, privacy: .public)")
    }

    static func describeScreen(_ screen: NSScreen) -> String {
        let frame = screen.frame
        let visibleFrame = screen.visibleFrame
        return String(
            format:
                "id=%@ frame=%.0fx%.0f@%.0f,%.0f visible=%.0fx%.0f@%.0f,%.0f scale=%.1f",
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber ?? -1,
            frame.width,
            frame.height,
            frame.minX,
            frame.minY,
            visibleFrame.width,
            visibleFrame.height,
            visibleFrame.minX,
            visibleFrame.minY,
            screen.backingScaleFactor
        )
    }

    private static func currentMemorySnapshot() -> MemorySnapshot? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        return MemorySnapshot(
            footprintMB: Int(info.phys_footprint / 1_048_576),
            residentMB: Int(info.resident_size / 1_048_576)
        )
    }

    private static func screenSummary() -> String {
        NSScreen.screens.enumerated()
            .map { index, screen in
                "screen\(index){\(describeScreen(screen))}"
            }
            .joined(separator: "|")
    }

    private static func uptimeSeconds() -> Int {
        Int(CFAbsoluteTimeGetCurrent() - launchTime)
    }
}

private enum DiagnosticsStore {
    static var fileURL: URL? {
        guard
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else { return nil }

        return
            appSupport
            .appendingPathComponent("SapoWhisper", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("runtime.jsonl")
    }

    private static let queue = DispatchQueue(label: "com.sapowhisper.diagnostics", qos: .utility)
    private static let maxFileBytes: UInt64 = 2_000_000

    static func append(_ payload: [String: Any]) {
        queue.async {
            guard let fileURL else { return }

            do {
                let directory = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try rotateIfNeeded(fileURL)

                var event = payload
                event["timestamp"] = ISO8601DateFormatter().string(from: Date())

                let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                guard var line = String(data: data, encoding: .utf8) else { return }
                line.append("\n")

                if FileManager.default.fileExists(atPath: fileURL.path) {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    try handle.seekToEnd()
                    if let lineData = line.data(using: .utf8) {
                        try handle.write(contentsOf: lineData)
                    }
                    try handle.close()
                } else {
                    try line.write(to: fileURL, atomically: true, encoding: .utf8)
                }
            } catch {
                SapoLog.performance.warning(
                    "Diagnostics file append failed error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func rotateIfNeeded(_ fileURL: URL) throws {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
            let size = attributes[.size] as? UInt64,
            size >= maxFileBytes
        else { return }

        let previousURL = fileURL.deletingLastPathComponent().appendingPathComponent("runtime.previous.jsonl")
        try? FileManager.default.removeItem(at: previousURL)
        try FileManager.default.moveItem(at: fileURL, to: previousURL)
    }
}
