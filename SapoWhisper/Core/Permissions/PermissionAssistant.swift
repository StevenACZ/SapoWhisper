//
//  PermissionAssistant.swift
//  SapoWhisper
//
//  Coordinates the floating guidance overlay shown during permission setup.
//

import AppKit

@MainActor
final class PermissionAssistant: NSObject {
    static let shared = PermissionAssistant()

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activePermission: AppPermission?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentOverlay = false

    private override init() {
        super.init()
    }

    func present(permission: AppPermission, sourceFrameInScreen: CGRect? = nil) {
        dismiss()

        activePermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        didPresentCurrentOverlay = false
        overlayController = PermissionOverlayWindowController(
            hostApp: PermissionHostApp.current(),
            permission: permission
        ) { [weak self] in
            self?.dismiss()
        }

        openSystemSettings(for: permission)
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        overlayController?.close()
        overlayController = nil
        activePermission = nil
        pendingSourceFrameInScreen = nil
        didPresentCurrentOverlay = false
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(
            timeInterval: 0.15,
            target: self,
            selector: #selector(handleTrackingTimer),
            userInfo: nil,
            repeats: true
        )

        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleApplicationActivation),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )

        refreshPosition()
    }

    @objc
    private func handleTrackingTimer() {
        refreshPosition()
    }

    @objc
    private func handleApplicationActivation(_ notification: Notification) {
        refreshPosition()
    }

    private func refreshPosition() {
        guard let permission = activePermission else { return }

        if permission.isGranted() {
            dismiss()
            return
        }

        guard let snapshot = PermissionSettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }

        if didPresentCurrentOverlay {
            overlayController?.updatePosition(with: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(
            from: pendingSourceFrameInScreen,
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }

    private func openSystemSettings(for permission: AppPermission) {
        let opened = permission.settingsURLs.contains { url in
            NSWorkspace.shared.open(url)
        }

        if !opened {
            NSLog("Failed to open System Settings for permission: %@", permission.title)
        }
    }
}
