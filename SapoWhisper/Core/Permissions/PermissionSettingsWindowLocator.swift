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

enum PermissionSettingsWindowLocator {
    private static let bundleIdentifier = "com.apple.systempreferences"

    static func frontmostWindow() -> PermissionSettingsWindowSnapshot? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
            return nil
        }

        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            return nil
        }

        guard
            let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                .zero
            ) as? [[String: Any]]
        else {
            return nil
        }

        let windows = windowInfo.compactMap { info -> PermissionSettingsWindowSnapshot? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == app.processIdentifier else {
                return nil
            }

            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }

            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }

            let cgFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )

            let converted = appKitGeometry(from: cgFrame)
            guard converted.frame.width > 320, converted.frame.height > 240 else {
                return nil
            }

            return PermissionSettingsWindowSnapshot(
                frame: converted.frame,
                visibleFrame: converted.visibleFrame
            )
        }

        return windows.max { lhs, rhs in
            lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
        }
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
