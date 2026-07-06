//
//  PermissionRequirementsWindowController.swift
//  SapoWhisper
//
//  Presents a lightweight window describing which permissions are missing.
//

import AppKit
import SwiftUI

@MainActor
final class PermissionRequirementsWindowController: NSWindowController {
    static let shared = PermissionRequirementsWindowController()

    private let windowSize = PermissionRequirementsView.windowSize
    private var hostingController: NSHostingController<AnyView>?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showWindow(force: Bool = false) {
        guard force || !PermissionService.shared.missingPermissions().isEmpty else {
            closeWindow()
            return
        }

        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = createWindow()
        let contentView = PermissionRequirementsView(
            onActivate: { [weak self] permission in
                self?.window?.makeFirstResponder(nil)
                PermissionService.shared.requestInteractively(permission)
            },
            onClose: { [weak self] in
                self?.closeWindow()
            }
        )

        let hostingController = NSHostingController(rootView: AnyView(contentView))
        // The window frame is the single source of truth for size; default
        // sizing options let the hosting view drive window min/max from inside
        // the update-constraints pass, which macOS 26 punishes with the
        // _postWindowNeedsUpdateConstraints hard crash (2026-07-05).
        hostingController.sizingOptions = []
        hostingController.view.frame = CGRect(origin: .zero, size: windowSize)

        window.contentViewController = hostingController
        self.hostingController = hostingController
        self.window = window

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        cleanup()
    }

    private func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "permissions.window_title".localized
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.level = .floating
        window.delegate = self
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        return window
    }

    private func cleanup() {
        if let hostingController {
            hostingController.view.removeFromSuperview()
            hostingController.rootView = AnyView(EmptyView())
        }

        if let window {
            window.contentViewController = nil
            window.contentView = nil
        }

        hostingController = nil
        window = nil
    }
}

extension PermissionRequirementsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cleanup()
    }
}
