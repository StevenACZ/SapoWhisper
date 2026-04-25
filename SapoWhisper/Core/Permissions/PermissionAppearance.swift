//
//  PermissionAppearance.swift
//  SapoWhisper
//
//  Shared appearance helpers for AppKit permission surfaces.
//

import AppKit

extension NSView {
    var permissionUsesDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func permissionCGColor(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
        var cgColor = color.withAlphaComponent(alpha).cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cgColor = color.withAlphaComponent(alpha).cgColor
        }
        return cgColor
    }
}
