//
//  PermissionOverlayWindowController.swift
//  SapoWhisper
//
//  Hosts the floating permission helper overlay shown over System Settings.
//

import AppKit
import QuartzCore

final class PermissionOverlayWindowController: NSWindowController {
    private var entrance: PermissionOverlayEntrance?
    private var measuredSize: CGSize?

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
        guard let target = targetFrame(settingsFrame: settingsFrame, visibleFrame: visibleFrame) else {
            hide()
            return
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let source = sourceFrameInScreen.flatMap { $0.isEmpty ? nil : $0 }
            entrance = PermissionOverlayEntrance(
                origin: source.map { NSPoint(x: $0.midX - target.width / 2, y: $0.midY - target.height / 2) }
                    ?? target.origin.applying(CGAffineTransform(translationX: 0, y: 12)),
                startedAt: CACurrentMediaTime()
            )
        }
        updatePosition(with: settingsFrame, visibleFrame: visibleFrame)
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window, let target = targetFrame(settingsFrame: settingsFrame, visibleFrame: visibleFrame) else {
            hide()
            return
        }
        var frame = target
        var alpha: CGFloat = 1
        if let entrance, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let progress = entrance.progress(at: CACurrentMediaTime())
            frame.origin = entrance.origin(toward: target.origin, progress: progress)
            alpha = progress
            if progress >= 1 { self.entrance = nil }
        } else {
            entrance = nil
        }
        if window.frame != frame { window.setFrame(frame, display: true) }
        if window.alphaValue != alpha { window.alphaValue = alpha }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        entrance = nil
        window?.orderOut(nil)
    }

    override func close() {
        entrance = nil
        super.close()
    }

    private func targetFrame(settingsFrame: CGRect, visibleFrame: CGRect) -> CGRect? {
        let visible = visibleFrame.insetBy(dx: 10, dy: 10)
        guard let column = PermissionOverlayPlacement.frame(settings: settingsFrame, visible: visible, height: 184),
            let content = window?.contentView as? PermissionOverlayContentView
        else { return nil }
        if measuredSize?.width != column.width {
            measuredSize = CGSize(width: column.width, height: content.preferredHeight(for: column.width))
        }
        return PermissionOverlayPlacement.frame(
            settings: settingsFrame, visible: visible, height: measuredSize?.height ?? column.height
        )
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
}

private final class PassiveOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
