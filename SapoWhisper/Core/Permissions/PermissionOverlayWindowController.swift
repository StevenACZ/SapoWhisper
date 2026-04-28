//
//  PermissionOverlayWindowController.swift
//  SapoWhisper
//
//  Hosts the floating permission helper overlay shown over System Settings.
//

import AppKit
import QuartzCore

final class PermissionOverlayWindowController: NSWindowController {
    private let windowSize = PermissionOverlayContentView.preferredSize

    init(hostApp: PermissionHostApp, permission: AppPermission, onClose: @escaping () -> Void) {
        let panel = PassiveOverlayPanel(
            contentRect: NSRect(origin: .zero, size: PermissionOverlayContentView.preferredSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)
        configureWindow(panel)
        panel.contentView = PermissionOverlayContentView(
            hostApp: hostApp,
            permission: permission,
            onClose: onClose
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(from sourceFrameInScreen: CGRect?, settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else { return }

        let targetOrigin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        let targetFrame = NSRect(origin: targetOrigin, size: windowSize)

        if let sourceFrameInScreen, !sourceFrameInScreen.isEmpty {
            window.alphaValue = 0.45
            window.setFrame(sourceFrameInScreen, display: false)
            window.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(targetFrame, display: true)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.setFrame(targetFrame, display: false)
            window.orderFrontRegardless()
        }
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        let origin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        window?.setFrameOrigin(origin)
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
    }

    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 168
        let contentMinX = settingsFrame.minX + sidebarWidth
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 10
        let preferredY = settingsFrame.minY + 22
        let minX = visibleFrame.minX + 10
        let maxX = visibleFrame.maxX - windowSize.width - 10
        let minY = visibleFrame.minY + 10
        let maxY = visibleFrame.maxY - windowSize.height - 10

        return NSPoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )
    }
}

private final class PassiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
