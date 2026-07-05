//
//  MenuBarStatusController.swift
//  SapoWhisper
//
//  Hosts the animated AppKit menu bar item and native popover.
//

import AppKit
import Combine
import QuartzCore
import SwiftUI
import os

@MainActor
final class MenuBarStatusController: NSObject, NSPopoverDelegate {
    private let viewModel: SapoWhisperViewModel
    private let localizationManager = LocalizationManager.shared
    private var cancellables = Set<AnyCancellable>()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var isPopoverTransitioning = false
    private var settingsWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private let secureInputReleaseDelegate = SecureInputReleasingWindowDelegate()
    private var pendingPopoverRefresh = false
    private var hiddenPopoverRefreshSkipCount = 0
    private var lastHiddenRefreshSkipLogTime: CFAbsoluteTime = 0
    private var popoverOpenCount = 0
    private var settingsOpenCount = 0
    private var historyOpenCount = 0
    private var historyFocusObserver: NSObjectProtocol?

    init(viewModel: SapoWhisperViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func start() {
        setupStatusItem()
        setupPopover()
        bindStatusImage()
        // The overlay result pill lives outside any SwiftUI window scene, so
        // it requests the History window through this notification.
        historyFocusObserver = NotificationCenter.default.addObserver(
            forName: HistoryFocusRequest.notification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openHistoryWindow()
            }
        }
    }

    func closePopover() {
        let t0 = CFAbsoluteTimeGetCurrent()
        popover?.performClose(nil)
        statusItem?.button?.state = .off
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SapoLog.menuBar.info("Popover close requested elapsed=\(elapsed, privacy: .public)ms")
    }

    func popoverWillClose(_ notification: Notification) {
        statusItem?.button?.state = .off
        SapoLog.menuBar.info("Popover will close")
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }
        button.image = currentStatusImage()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = makePopoverContentController()
        self.popover = popover
        refreshPopoverSize(reason: "setup", force: true)
    }

    private func bindStatusImage() {
        Publishers.CombineLatest(viewModel.$appState, viewModel.isLoadingWhisperKitSubject)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.statusItem?.button?.image = self?.currentStatusImage()
            }
            .store(in: &cancellables)

        let appStateRefreshes = viewModel.$appState
            .dropFirst()
            .removeDuplicates()
            .map { _ in "app-state" }
            .eraseToAnyPublisher()

        let transcriptionRefreshes = viewModel.$lastTranscription
            .dropFirst()
            .removeDuplicates()
            .map { _ in "last-transcription" }
            .eraseToAnyPublisher()

        let loadingRefreshes = viewModel.isLoadingWhisperKitSubject
            .dropFirst()
            .removeDuplicates()
            .map { _ in "whisper-loading" }
            .eraseToAnyPublisher()

        let reachabilityRefreshes = NetworkReachability.shared.$isOnline
            .dropFirst()
            .removeDuplicates()
            .map { _ in "reachability" }
            .eraseToAnyPublisher()

        // L9: state ticks can burst (recording → processing → polishing →
        // idle); one re-measure per 150ms window is plenty for a popover.
        Publishers.Merge4(appStateRefreshes, transcriptionRefreshes, loadingRefreshes, reachabilityRefreshes)
            .throttle(for: .milliseconds(150), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] reason in
                self?.schedulePopoverRefresh(reason: reason)
            }
            .store(in: &cancellables)

        localizationManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.schedulePopoverRefresh(reason: "localization")
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        guard !isPopoverTransitioning else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        lockPopoverTransition()
        animateStatusButton(button)

        if popover.isShown {
            closePopover()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            SapoLog.menuBar.info("Popover toggle closed elapsed=\(elapsed, privacy: .public)ms")
        } else {
            popoverOpenCount += 1
            // R3: reuse the hosting controller across opens; only the root
            // view is refreshed (missing permissions may have changed).
            if let hostingController = popover.contentViewController as? NSHostingController<MenuBarPopoverHost> {
                hostingController.rootView = makePopoverHost()
            } else {
                popover.contentViewController = makePopoverContentController()
            }
            refreshPopoverSize(reason: "open", force: true)
            button.state = .on
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            PerformanceDiagnostics.logRuntimeSnapshot(
                reason: "popover-open",
                context: "openCount=\(popoverOpenCount)",
                force: true
            )

            DispatchQueue.main.async { [weak self] in
                self?.refreshPopoverSize(reason: "post-open", force: true)
            }
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            SapoLog.menuBar.info("Popover toggle opened elapsed=\(elapsed, privacy: .public)ms")
        }
    }

    private func schedulePopoverRefresh(reason: String) {
        guard popover?.isShown == true else {
            recordHiddenPopoverRefreshSkip()
            return
        }
        guard !pendingPopoverRefresh else { return }

        pendingPopoverRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPopoverRefresh = false
            self.refreshPopoverSize(reason: reason)
        }
    }

    private func recordHiddenPopoverRefreshSkip() {
        hiddenPopoverRefreshSkipCount += 1

        let now = CFAbsoluteTimeGetCurrent()
        guard hiddenPopoverRefreshSkipCount >= 100 || now - lastHiddenRefreshSkipLogTime >= 60 else { return }

        SapoLog.menuBar.info(
            "Skipped hidden popover refreshes count=\(self.hiddenPopoverRefreshSkipCount, privacy: .public)"
        )
        hiddenPopoverRefreshSkipCount = 0
        lastHiddenRefreshSkipLogTime = now
    }

    private func refreshPopoverSize(reason: String, force: Bool = false) {
        guard force || popover?.isShown == true else {
            recordHiddenPopoverRefreshSkip()
            return
        }

        guard
            let popover,
            let hostingController = popover.contentViewController as? NSHostingController<MenuBarPopoverHost>
        else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let width = Constants.Sizes.menuBarWidth
        let fittingSize = hostingController.sizeThatFits(
            in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        let measuredHeight = ceil(fittingSize.height)
        let height = min(max(measuredHeight, 1), 680)

        popover.contentSize = NSSize(width: width, height: height)

        let view = hostingController.view
        view.setFrameSize(popover.contentSize)
        view.layoutSubtreeIfNeeded()

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if elapsed >= 16 {
            SapoLog.menuBar.info(
                "Popover size refreshed reason=\(reason, privacy: .public) elapsed=\(elapsed, privacy: .public)ms height=\(Int(height), privacy: .public)"
            )
        }
    }

    private func lockPopoverTransition() {
        isPopoverTransitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.isPopoverTransitioning = false
        }
    }

    private func makePopoverContentController() -> NSHostingController<MenuBarPopoverHost> {
        NSHostingController(rootView: makePopoverHost())
    }

    private func makePopoverHost() -> MenuBarPopoverHost {
        MenuBarPopoverHost(
            viewModel: viewModel,
            missingPermissions: PermissionService.shared.missingPermissions(),
            openSettings: { [weak self] in self?.openSettingsWindow() },
            openHistory: { [weak self] in self?.openHistoryWindow() },
            openPermissions: { [weak self] in self?.openPermissionsWindow() },
            openWelcome: { [weak self] in self?.openWelcomeWindow() },
            openAbout: { [weak self] in self?.openAboutWindow() },
            closePopover: { [weak self] in self?.closePopover() }
        )
    }

    private func currentStatusImage() -> NSImage {
        MenuBarIconImageProvider.image(
            for: viewModel.appState,
            isLoadingWhisperKit: viewModel.isLoadingWhisperKit
        )
    }

    private func animateStatusButton(_ button: NSStatusBarButton) {
        button.wantsLayer = true

        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 0.86, 1.08, 1.0]
        animation.keyTimes = [0, 0.35, 0.75, 1]
        animation.duration = 0.28
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]

        button.layer?.add(animation, forKey: "sapoStatusPress")
    }

    func openSettingsWindow() {
        settingsOpenCount += 1
        SapoLog.settings.info("Settings open requested from menu bar")
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "settings-open",
            context: "openCount=\(settingsOpenCount)",
            force: true
        )
        closePopover()

        DispatchQueue.main.async { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    private func presentSettingsWindow() {
        let t0 = CFAbsoluteTimeGetCurrent()
        let controller =
            settingsWindowController
            ?? makeWindowController(
                size: NSSize(width: 800, height: 560),
                resizable: false,
                rootView: SettingsWindowHost(viewModel: viewModel)
            )
        settingsWindowController = controller
        show(controller)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SapoLog.settings.info("Settings window presented elapsed=\(elapsed, privacy: .public)ms")
    }

    func openHistoryWindow() {
        historyOpenCount += 1
        PerformanceDiagnostics.logRuntimeSnapshot(
            reason: "history-open",
            context: "openCount=\(historyOpenCount)",
            force: true
        )
        closePopover()

        let controller =
            historyWindowController
            ?? makeWindowController(
                size: NSSize(width: 1000, height: 640),
                resizable: true,
                rootView: HistoryWindowHost(viewModel: viewModel)
            )
        historyWindowController = controller
        show(controller)
    }

    private func openPermissionsWindow() {
        closePopover()
        PermissionRequirementsWindowController.shared.showWindow(force: true)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openWelcomeWindow() {
        closePopover()
        WelcomeWindowController.shared.show()
    }

    func openAboutWindow() {
        closePopover()
        let controller = aboutWindowController ?? makeAboutWindowController()
        aboutWindowController = controller
        show(controller)
    }

    /// The About window sizes itself to its content and hides the resize
    /// affordances; everything else follows the shared window styling.
    private func makeAboutWindowController() -> NSWindowController {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        let hostingController = NSHostingController(rootView: AboutWindowHost())
        window.contentViewController = hostingController
        window.setContentSize(hostingController.view.fittingSize)
        return NSWindowController(window: window)
    }

    private func makeWindowController<Content: View>(
        size: NSSize,
        resizable: Bool,
        rootView: Content
    ) -> NSWindowController {
        var styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable {
            styleMask.insert(.resizable)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = secureInputReleaseDelegate
        window.contentViewController = NSHostingController(rootView: rootView)
        window.contentView?.wantsLayer = true
        // NSHostingController shrinks the window to the view's minimum once
        // assigned; restore the size this window was asked to open at.
        window.setContentSize(size)

        if resizable {
            window.contentMinSize = NSSize(width: 700, height: 420)
        }

        return NSWindowController(window: window)
    }

    private func show(_ controller: NSWindowController) {
        guard let window = controller.window else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        let shouldCenter = !window.isVisible
        NSApp.activate(ignoringOtherApps: true)

        if shouldCenter {
            window.center()
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        refreshWindowRendering(window)
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SapoLog.menuBar.info(
            "Window shown visibleBefore=\((!shouldCenter), privacy: .public) elapsed=\(elapsed, privacy: .public)ms"
        )
    }

    private func refreshWindowRendering(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        let t0 = CFAbsoluteTimeGetCurrent()
        contentView.layoutSubtreeIfNeeded()
        contentView.needsDisplay = true
        contentView.displayIfNeeded()
        let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if elapsed >= 16 {
            SapoLog.menuBar.info("Window render refreshed elapsed=\(elapsed, privacy: .public)ms")
        }

        DispatchQueue.main.async { [weak window] in
            guard let contentView = window?.contentView else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            contentView.layoutSubtreeIfNeeded()
            contentView.needsDisplay = true
            contentView.displayIfNeeded()
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            if elapsed >= 16 {
                SapoLog.menuBar.info("Window deferred render refreshed elapsed=\(elapsed, privacy: .public)ms")
            }
        }
    }
}

/// A focused SecureField (API key inputs) keeps macOS Secure Keyboard Entry
/// enabled, which silently starves the global hotkey event tap until focus
/// moves inside the app. Dropping the first responder whenever a settings or
/// history window closes or resigns key releases it immediately.
@MainActor
final class SecureInputReleasingWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        (notification.object as? NSWindow)?.makeFirstResponder(nil)
    }

    func windowWillClose(_ notification: Notification) {
        (notification.object as? NSWindow)?.makeFirstResponder(nil)
        HotkeyManager.shared.assertHotkeyAlive(reason: "window-closed")
    }
}
