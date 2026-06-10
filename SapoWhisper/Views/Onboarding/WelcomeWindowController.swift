//
//  WelcomeWindowController.swift
//  SapoWhisper
//
//  Hosts the multi-step Welcome flow. Shown on first run (or after an
//  upgrade that removed the previously selected engine) and re-openable
//  any time from the menu bar.
//

import AppKit
import Combine
import SwiftUI
import os

struct WelcomeWindowHost: View {
    @ObservedObject var viewModel: SapoWhisperViewModel
    @ObservedObject private var localizationManager = LocalizationManager.shared
    let onFinish: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        WelcomeView(viewModel: viewModel, onFinish: onFinish, onDismiss: onDismiss)
            .environment(\.locale, localizationManager.locale)
            .tint(Constants.Colors.sapoGreen)
            .id(localizationManager.language)
    }
}

@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private var hostingController: NSHostingController<AnyView>?
    private var dictationObserver: AnyCancellable?

    private init() {
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Fresh install or upgrade where the previous engine was removed and no
    /// usable engine remains. Existing configured setups never see the flow.
    static var isOnboardingNeeded: Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Constants.StorageKeys.onboardingComplete) else { return false }
        guard !hasUsableEngine else {
            // Configured before this flow existed — mark complete silently.
            defaults.set(true, forKey: Constants.StorageKeys.onboardingComplete)
            return false
        }
        return true
    }

    private static var hasUsableEngine: Bool {
        // Hint-based checks: this runs unprompted at launch, so it must never
        // be the reason the keychain consent dialog appears.
        if KeychainStore.hasValue(for: .deepgramAPIKey) {
            return true
        }
        if KeychainStore.hasValue(for: .elevenLabsAPIKey) {
            return true
        }
        let viewModel = SapoWhisperAppEnvironment.shared.viewModel
        return viewModel.whisperKitTranscriber.isModelDownloaded(viewModel.currentWhisperKitModel)
    }

    func show() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SapoWhisperAppEnvironment.shared.viewModel
        let window = createWindow()
        let content = WelcomeWindowHost(
            viewModel: viewModel,
            onFinish: { [weak self] in self?.markCompletedAndClose() },
            onDismiss: { [weak self] in self?.dismissForGood() }
        )

        let hostingController = NSHostingController(rootView: AnyView(content))
        // The window frame is the single source of truth for size; otherwise
        // AppKit re-applies the SwiftUI fitting size when presenting and the
        // flexible-height content would collapse.
        hostingController.sizingOptions = []
        hostingController.view.frame = CGRect(origin: .zero, size: WelcomeView.windowSize)
        window.contentViewController = hostingController
        self.hostingController = hostingController
        self.window = window

        // The flow also completes itself on the first successful dictation.
        dictationObserver = viewModel.$lastTranscription
            .dropFirst()
            .filter { !$0.isEmpty }
            .first()
            .sink { [weak self] _ in
                self?.markCompletedAndClose()
            }

        SapoLog.lifecycle.info("Welcome flow presented")
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        window?.close()
        cleanup()
    }

    private func markCompletedAndClose() {
        UserDefaults.standard.set(true, forKey: Constants.StorageKeys.onboardingComplete)
        SapoLog.lifecycle.info("Welcome flow completed")
        closeWindow()
    }

    /// An explicit Close counts as "seen": the flow must never auto-reappear
    /// on later launches. The menu bar still offers the tour and setup hints.
    private func dismissForGood() {
        UserDefaults.standard.set(true, forKey: Constants.StorageKeys.onboardingComplete)
        SapoLog.lifecycle.info("Welcome flow dismissed")
        closeWindow()
    }

    private func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeView.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "welcome.window_title".localized
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        // The flow closes only through its own Close/finish buttons; the
        // stray traffic light looked broken on the borderless titlebar.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        return window
    }

    private func cleanup() {
        dictationObserver?.cancel()
        dictationObserver = nil

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

extension WelcomeWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cleanup()
    }
}
