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

    init(viewModel: SapoWhisperViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func start() {
        setupStatusItem()
        setupPopover()
        bindStatusImage()
    }

    func closePopover() {
        popover?.performClose(nil)
        statusItem?.button?.state = .off
    }

    func popoverWillClose(_ notification: Notification) {
        statusItem?.button?.state = .off
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
        refreshPopoverSize()
    }

    private func bindStatusImage() {
        Publishers.CombineLatest(viewModel.$appState, viewModel.$isLoadingWhisperKit)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.statusItem?.button?.image = self?.currentStatusImage()
            }
            .store(in: &cancellables)

        viewModel.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.refreshPopoverSize()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        guard !isPopoverTransitioning else { return }

        lockPopoverTransition()
        animateStatusButton(button)

        if popover.isShown {
            closePopover()
        } else {
            popover.contentViewController = makePopoverContentController()
            refreshPopoverSize()
            button.state = .on
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)

            DispatchQueue.main.async { [weak self] in
                self?.refreshPopoverSize()
            }
        }
    }

    private func refreshPopoverSize() {
        guard
            let popover,
            let hostingController = popover.contentViewController as? NSHostingController<MenuBarPopoverHost>
        else { return }

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
    }

    private func lockPopoverTransition() {
        isPopoverTransitioning = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.isPopoverTransitioning = false
        }
    }

    private func makePopoverContentController() -> NSHostingController<MenuBarPopoverHost> {
        let missingPermissions = PermissionService.shared.missingPermissions()

        return NSHostingController(
            rootView: MenuBarPopoverHost(
                viewModel: viewModel,
                missingPermissions: missingPermissions,
                openSettings: { [weak self] in self?.openSettingsWindow() },
                openHistory: { [weak self] in self?.openHistoryWindow() },
                openPermissions: { [weak self] in self?.openPermissionsWindow() },
                closePopover: { [weak self] in self?.closePopover() }
            )
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

    private func openSettingsWindow() {
        closePopover()

        DispatchQueue.main.async { [weak self] in
            self?.presentSettingsWindow()
        }
    }

    private func presentSettingsWindow() {
        let controller =
            settingsWindowController
            ?? makeWindowController(
                size: NSSize(width: 480, height: 500),
                resizable: false,
                rootView: SettingsWindowHost(viewModel: viewModel)
            )
        settingsWindowController = controller
        show(controller)
    }

    private func openHistoryWindow() {
        closePopover()

        let controller =
            historyWindowController
            ?? makeWindowController(
                size: NSSize(width: 900, height: 560),
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
        window.contentViewController = NSHostingController(rootView: rootView)
        window.contentView?.wantsLayer = true

        if resizable {
            window.contentMinSize = NSSize(width: 700, height: 420)
        }

        return NSWindowController(window: window)
    }

    private func show(_ controller: NSWindowController) {
        guard let window = controller.window else { return }

        let shouldCenter = !window.isVisible
        NSApp.activate(ignoringOtherApps: true)

        if shouldCenter {
            window.center()
        }

        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        refreshWindowRendering(window)
    }

    private func refreshWindowRendering(_ window: NSWindow) {
        guard let contentView = window.contentView else { return }

        contentView.layoutSubtreeIfNeeded()
        contentView.needsDisplay = true
        contentView.displayIfNeeded()

        DispatchQueue.main.async { [weak window] in
            guard let contentView = window?.contentView else { return }
            contentView.layoutSubtreeIfNeeded()
            contentView.needsDisplay = true
            contentView.displayIfNeeded()
        }
    }
}
