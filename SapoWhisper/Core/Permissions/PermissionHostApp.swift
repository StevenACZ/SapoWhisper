//
//  PermissionHostApp.swift
//  SapoWhisper
//
//  Provides the bundle metadata used by the permission assistant overlay.
//

import AppKit

struct PermissionHostApp {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermissionHostApp {
        let displayName =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent

        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)

        return PermissionHostApp(
            displayName: displayName,
            bundleURL: bundle.bundleURL,
            icon: icon
        )
    }
}
