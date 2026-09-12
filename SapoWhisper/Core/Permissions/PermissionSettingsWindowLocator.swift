//
//  PermissionSettingsWindowLocator.swift
//  SapoWhisper
//
//  Locates the active System Settings privacy window for the assistant overlay.
//

import AppKit
import CoreGraphics

struct PermissionSettingsWindowSnapshot: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

@MainActor
final class PermissionSettingsWindowLocator {
    private var windowID: CGWindowID?
    private var ownerPID: pid_t?

    func reset() {
        windowID = nil
        ownerPID = nil
    }

    func trackedWindow() -> PermissionSettingsWindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier == "com.apple.systempreferences",
            app.processIdentifier == ownerPID, let windowID,
            let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
            let info = windows.first
        else { return nil }
        return snapshot(info, ownerPID: app.processIdentifier)
    }

    func discover() -> PermissionSettingsWindowSnapshot? {
        if let tracked = trackedWindow() { return tracked }
        reset()
        guard let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier == "com.apple.systempreferences",
            let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], .zero
            ) as? [[String: Any]]
        else { return nil }
        for info in windows {
            guard let found = snapshot(info, ownerPID: app.processIdentifier),
                let number = info[kCGWindowNumber as String] as? NSNumber
            else { continue }
            ownerPID = app.processIdentifier
            windowID = number.uint32Value
            return found
        }
        return nil
    }

    private func snapshot(_ info: [String: Any], ownerPID: pid_t) -> PermissionSettingsWindowSnapshot? {
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownerPID,
            (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
            (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
            cgFrame.width > 320, cgFrame.height > 240
        else { return nil }
        let converted = Self.appKitGeometry(from: cgFrame)
        return PermissionSettingsWindowSnapshot(frame: converted.frame, visibleFrame: converted.visibleFrame)
    }

    private static func appKitGeometry(from cgFrame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, visibleFrame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return (
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                cgBounds: CGDisplayBounds(displayID)
            )
        }

        let matchedScreen =
            screens
            .filter { $0.cgBounds.intersects(cgFrame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(cgFrame).width * lhs.cgBounds.intersection(cgFrame).height
                    < rhs.cgBounds.intersection(cgFrame).width * rhs.cgBounds.intersection(cgFrame).height
            }

        guard let matchedScreen else {
            let visibleFrame = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: cgFrame.size)
            return (frame: cgFrame, visibleFrame: visibleFrame)
        }

        let localX = cgFrame.minX - matchedScreen.cgBounds.minX
        let localY = cgFrame.minY - matchedScreen.cgBounds.minY
        let frame = CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )

        return (frame: frame, visibleFrame: matchedScreen.visibleFrame)
    }
}
