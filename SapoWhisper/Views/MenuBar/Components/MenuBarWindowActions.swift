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
        openHistoryAction?()
    }

    func openSettingsWindow() {
        closeMenuBar()
        openSettingsAction?()
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

    func openAboutWindow() {
        closeMenuBar()
        openAboutAction?()
    }

    func closeMenuBar() {
        if let closeMenuBarAction {
            closeMenuBarAction()
        } else {
            NSApp.keyWindow?.close()
        }
    }
}
