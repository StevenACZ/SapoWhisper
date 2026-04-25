//
//  MenuBarWindowActions.swift
//  SapoWhisper
//
//  Window-routing helpers used by the menu bar popover.
//

import SwiftUI

extension MenuBarView {
    func openHistoryWindow() {
        closeMenuBar()
        if let openHistoryAction {
            openHistoryAction()
            return
        }

        openWindow(id: "history")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func openSettingsWindow() {
        closeMenuBar()
        if let openSettingsAction {
            openSettingsAction()
            return
        }

        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func openPermissionsWindow() {
        closeMenuBar()
        if let openPermissionsAction {
            openPermissionsAction()
            return
        }

        PermissionRequirementsWindowController.shared.showWindow(force: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func closeMenuBar() {
        if let closeMenuBarAction {
            closeMenuBarAction()
        } else {
            NSApp.keyWindow?.close()
        }
    }
}
