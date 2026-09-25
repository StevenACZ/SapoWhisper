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

        PermissionService.shared.flow.present()
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
