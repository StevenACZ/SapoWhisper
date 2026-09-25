// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import QuartzCore
import SwiftUI

@MainActor
public final class PermissionFlow {
  public let model: PermissionFlowModel
  public var onFinish: ((Bool) -> Void)?
  private var controller: PermissionFlowWindowController?

  public init(configuration: PermissionFlowConfiguration) {
    model = PermissionFlowModel(configuration: configuration)
  }

  public var isPresented: Bool { controller != nil }

  @discardableResult
  public func presentIfNeeded() -> Bool {
    guard model.shouldPresentAtLaunch else { return false }
    present()
    return true
  }

  public func present() {
    if let controller {
      controller.bringToFront()
      return
    }
    let controller = PermissionFlowWindowController(model: model)
    controller.onClose = { [weak self] completed in
      self?.controller = nil
      self?.onFinish?(completed)
    }
    self.controller = controller
    controller.show()
  }

  public func close() {
    controller?.close()
  }
}

@MainActor
final class PermissionFlowWindowController: NSObject, NSWindowDelegate {
  static let width: CGFloat = 468
  let model: PermissionFlowModel
  var onClose: ((Bool) -> Void)?
  private var window: NSWindow?
  private var completed = false
  private var closing = false

  init(model: PermissionFlowModel) {
    self.model = model
    super.init()
  }

  func show() {
    let text = PermissionFlowStrings(model.language)
    let height = measuredHeight()
    let size = CGSize(width: Self.width, height: height)
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    window.title = text.windowTitle(model.configuration.appName)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.backgroundColor = .windowBackgroundColor
    window.standardWindowButton(.miniaturizeButton)?.isHidden = true
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenNone]
    window.delegate = self
    let container = PermissionFlowBackdrop(frame: CGRect(origin: .zero, size: size))
    let hosting = NSHostingView(
      rootView: PermissionFlowScreen(
        model: model, height: height,
        sourceFrame: { [weak self] in self?.window?.frame },
        finish: { [weak self] in self?.finish() },
        later: { [weak self] in self?.close() }))
    hosting.sizingOptions = []
    hosting.frame = container.bounds
    hosting.autoresizingMask = [.width, .height]
    container.addSubview(hosting)
    window.contentView = container
    window.setContentSize(size)
    window.center()
    if let screen = window.screen ?? NSScreen.main {
      var frame = window.frame
      frame.origin.y = min(
        screen.visibleFrame.maxY - frame.height - 40,
        frame.origin.y + screen.visibleFrame.height * 0.06)
      window.setFrameOrigin(CGPoint(x: frame.origin.x.rounded(), y: frame.origin.y.rounded()))
    }
    self.window = window
    model.startMonitoring()
    window.alphaValue = 0
    PermissionFlowActivation.bringForward(window)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.28
      window.animator().alphaValue = 1
    }
  }

  func bringToFront() {
    guard let window else { return }
    PermissionFlowActivation.bringForward(window)
  }

  func close() {
    window?.close()
  }

  private func measuredHeight() -> CGFloat {
    let probe = NSHostingView(
      rootView: PermissionFlowScreen(
        model: model, height: nil, sourceFrame: { nil }, finish: {}, later: {}))
    let fitting = probe.fittingSize.height
    return max(430, ceil(fitting))
  }

  private func finish() {
    guard !closing, let window else { return }
    closing = true
    completed = true
    model.markCompleted()
    model.stopMonitoring()
    let anchor = model.configuration.menuBarAnchor?()
    PermissionFlowDismissal.run(window: window, toward: anchor) { [weak self] in
      self?.window?.close()
    }
  }

  func windowWillClose(_ notification: Notification) {
    model.stopMonitoring()
    window?.delegate = nil
    window = nil
    if !completed && model.ready {
      completed = true
      model.markCompleted()
    }
    onClose?(completed)
  }
}

final class PermissionFlowBackdrop: NSView {
  override var isOpaque: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
}

public struct PermissionFlowScreen: View {
  @ObservedObject var model: PermissionFlowModel
  let height: CGFloat?
  let sourceFrame: () -> CGRect?
  let finish: () -> Void
  let later: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var welcome = false
  @State private var appeared = false

  public init(
    model: PermissionFlowModel, height: CGFloat?, sourceFrame: @escaping () -> CGRect? = { nil },
    finish: @escaping () -> Void, later: @escaping () -> Void
  ) {
    self.model = model
    self.height = height
    self.sourceFrame = sourceFrame
    self.finish = finish
    self.later = later
  }

  public var body: some View {
    ZStack(alignment: .top) {
      LinearGradient(
        colors: [model.configuration.accent.opacity(0.13), .clear],
        startPoint: .top, endPoint: .center
      )
      .ignoresSafeArea()
      if welcome {
        PermissionFlowWelcomeView(model: model, onDone: finish)
          .padding(.horizontal, 32)
          .padding(.top, 34)
          .padding(.bottom, 26)
          .transition(
            .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
      } else {
        checklist
          .transition(.opacity.combined(with: .scale(scale: 1.02)))
      }
    }
    .frame(width: PermissionFlowWindowController.width)
    .frame(height: height)
    .onAppear {
      if height != nil && model.ready { welcome = true }
      appeared = true
    }
    .onChange(of: model.ready) { _, satisfied in
      guard satisfied, !welcome, height != nil else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 650))
        withAnimation(
          reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.86)
        ) {
          welcome = true
        }
      }
    }
  }

  private var checklist: some View {
    let text = PermissionFlowStrings(model.language)
    let name = model.configuration.appName
    return VStack(spacing: 0) {
      VStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(
              RadialGradient(
                colors: [model.configuration.accent.opacity(0.3), .clear], center: .center,
                startRadius: 4, endRadius: 64)
            )
            .frame(width: 128, height: 128)
          Image(nsImage: model.configuration.icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 76, height: 76)
            .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.8)
            .opacity(appeared ? 1 : 0)
            .animation(
              reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.7), value: appeared)
        }
        .frame(height: 96)
        Text(text.headline(name))
          .font(.system(size: 22, weight: .bold, design: .rounded))
          .multilineTextAlignment(.center)
        Text(
          text.subtitle(
            name, required: model.requiredItems.count,
            optional: model.items.count - model.requiredItems.count)
        )
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, 30)
      PermissionFlowChecklist(model: model, sourceFrame: sourceFrame)
        .padding(.top, 22)
      if let note = model.configuration.note {
        Text(note.resolve(model.language))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 14)
      }
      Spacer(minLength: 16)
      Button(text.later, action: later)
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .padding(.horizontal, 28)
    .padding(.bottom, 18)
  }
}

@MainActor
enum PermissionFlowDismissal {
  static func run(
    window: NSWindow, toward anchor: CGRect?, completion: @escaping @MainActor @Sendable () -> Void
  ) {
    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
      let content = window.contentView,
      let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)
    else {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        window.animator().alphaValue = 0
      } completionHandler: {
        MainActor.assumeIsolated { completion() }
      }
      return
    }
    content.cacheDisplay(in: content.bounds, to: rep)
    let frame = window.frame
    let ghost = NSWindow(
      contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    ghost.isOpaque = false
    ghost.backgroundColor = .clear
    ghost.hasShadow = true
    ghost.level = .floating
    ghost.isReleasedWhenClosed = false
    ghost.ignoresMouseEvents = true
    let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
    view.wantsLayer = true
    view.layer?.contents = rep.cgImage
    view.layer?.contentsGravity = .resize
    view.layer?.cornerRadius = 16
    view.layer?.cornerCurve = .continuous
    view.layer?.masksToBounds = true
    view.autoresizingMask = [.width, .height]
    ghost.contentView = view
    ghost.setFrame(frame, display: false)
    ghost.orderFront(nil)
    window.alphaValue = 0
    let target: CGRect
    if let anchor, !anchor.isEmpty {
      target = CGRect(x: anchor.midX - 14, y: anchor.midY - 10, width: 28, height: 20)
    } else {
      target = frame.insetBy(dx: frame.width * 0.06, dy: frame.height * 0.06).offsetBy(
        dx: 0, dy: 10)
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = anchor == nil ? 0.32 : 0.55
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.75, 0.35)
      ghost.animator().setFrame(target, display: true)
      ghost.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        ghost.orderOut(nil)
        completion()
      }
    }
  }
}
