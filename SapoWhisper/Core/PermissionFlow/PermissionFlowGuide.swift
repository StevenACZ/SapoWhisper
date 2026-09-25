// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import Combine
import QuartzCore
import SwiftUI

@MainActor
final class PermissionFlowGuide: NSObject {
  private let panel: PermissionFlowGuidePanel
  private let locator = PermissionFlowSettingsLocator()
  private let sourceFrame: CGRect?
  private var discoveryTimer: Timer?
  private var displayLink: CADisplayLink?
  private var presented = false
  private var entering = false
  private var completed = false

  init(
    kind: PermissionFlowKind, model: PermissionFlowModel, sourceFrame: CGRect?,
    close: @escaping () -> Void
  ) {
    self.sourceFrame = sourceFrame
    panel = PermissionFlowGuidePanel(kind: kind, model: model, close: close)
    super.init()
  }

  func start() {
    discoveryTimer = Timer.scheduledTimer(
      timeInterval: 0.5, target: self, selector: #selector(discover), userInfo: nil, repeats: true)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(discover),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
    discover()
  }

  func stop() {
    discoveryTimer?.invalidate()
    discoveryTimer = nil
    stopTracking()
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    panel.orderOut(nil)
  }

  func showSuccess() {
    completed = true
    panel.state.success = true
  }

  @objc private func discover() {
    guard !completed else { return }
    guard let frame = locator.locate() else {
      panel.orderOut(nil)
      stopTracking()
      return
    }
    position(frame)
    guard panel.isVisible else {
      stopTracking()
      return
    }
    guard displayLink == nil else { return }
    let link = panel.displayLink(target: self, selector: #selector(track))
    link.add(to: .main, forMode: .common)
    displayLink = link
    updateRefreshRate()
  }

  @objc private func track() {
    guard let frame = locator.locate() else {
      if !completed { panel.orderOut(nil) }
      stopTracking()
      return
    }
    position(frame)
    guard panel.isVisible else {
      stopTracking()
      return
    }
    updateRefreshRate()
  }

  private func stopTracking() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func updateRefreshRate() {
    guard let displayLink else { return }
    let rate = Float(min(120, max(30, panel.screen?.maximumFramesPerSecond ?? 60)))
    if displayLink.preferredFrameRateRange.maximum != rate {
      displayLink.preferredFrameRateRange = CAFrameRateRange(
        minimum: min(60, rate), maximum: rate, preferred: rate)
    }
  }

  private func position(_ settingsFrame: CGRect) {
    guard !entering else { return }
    let screen =
      NSScreen.screens.max {
        $0.frame.intersection(settingsFrame).coveredArea
          < $1.frame.intersection(settingsFrame).coveredArea
      } ?? NSScreen.main
    guard let screen else { return }
    let visible = screen.visibleFrame.insetBy(dx: 10, dy: 10)
    guard let target = PermissionFlowPlacement.frame(settings: settingsFrame, visible: visible)
    else {
      panel.orderOut(nil)
      return
    }
    if !presented {
      presented = true
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        enter(to: target)
        return
      }
    }
    if panel.frame.size != target.size {
      panel.setFrame(target, display: true)
    } else if panel.frame.origin != target.origin {
      panel.setFrameOrigin(target.origin)
    }
    if !panel.isVisible { panel.orderFrontRegardless() }
  }

  private func enter(to target: CGRect) {
    entering = true
    panel.alphaValue = 0
    let start =
      sourceFrame.map {
        CGRect(
          x: ($0.midX - target.width / 2).rounded(), y: ($0.midY - target.height / 2).rounded(),
          width: target.width, height: target.height)
      } ?? target.offsetBy(dx: 0, dy: -14)
    panel.setFrame(start, display: false)
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.34
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
      panel.animator().setFrame(target, display: true)
      panel.animator().alphaValue = 1
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        self?.entering = false
        self?.panel.state.arrived += 1
      }
    }
  }
}

enum PermissionFlowPlacement {
  static let height: CGFloat = 112

  static func frame(settings: CGRect, visible: CGRect) -> CGRect? {
    let sidebar = min(240, max(180, settings.width * 0.31))
    let left = max(settings.minX + sidebar + 20, visible.minX)
    let right = min(settings.maxX - 20, visible.maxX)
    let bottom = max(settings.minY + 20, visible.minY)
    let top = min(settings.maxY - 20, visible.maxY)
    guard right - left >= 240, top - bottom >= height else { return nil }
    return CGRect(
      x: left.rounded(.up), y: bottom.rounded(.up),
      width: right.rounded(.down) - left.rounded(.up), height: height)
  }
}

@MainActor
final class PermissionFlowSettingsLocator {
  private var windowID: CGWindowID?
  private var ownerPID: pid_t?

  func locate() -> CGRect? {
    guard let app = NSWorkspace.shared.frontmostApplication,
      app.bundleIdentifier == "com.apple.systempreferences"
    else { return nil }
    if app.processIdentifier != ownerPID {
      ownerPID = app.processIdentifier
      windowID = nil
    }
    if let windowID,
      let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID)
        as? [[String: Any]],
      let window = windows.first, let frame = frame(of: window, pid: app.processIdentifier)
    {
      return frame
    }
    windowID = nil
    guard
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for window in windows {
      if let frame = frame(of: window, pid: app.processIdentifier) {
        windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        return frame
      }
    }
    return nil
  }

  private func frame(of window: [String: Any], pid: pid_t) -> CGRect? {
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
      let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
      let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
      frame.width > 300, frame.height > 250
    else { return nil }
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
  }
}

@MainActor
public final class PermissionFlowGuideState: ObservableObject {
  @Published public var success = false
  @Published public var arrived = 0

  public init() {}
}

@MainActor
final class PermissionFlowGuidePanel: NSPanel {
  let state = PermissionFlowGuideState()

  init(kind: PermissionFlowKind, model: PermissionFlowModel, close: @escaping () -> Void) {
    super.init(
      contentRect: CGRect(x: 0, y: 0, width: 420, height: PermissionFlowPlacement.height),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    isReleasedWhenClosed = false
    let hosting = NSHostingView(
      rootView: PermissionFlowGuideCard(kind: kind, model: model, state: state, close: close))
    hosting.sizingOptions = []
    contentView = hosting
  }

  override var canBecomeKey: Bool { false }
}

public struct PermissionFlowGuideCard: View {
  let kind: PermissionFlowKind
  @ObservedObject var model: PermissionFlowModel
  @ObservedObject var state: PermissionFlowGuideState
  let close: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  public init(
    kind: PermissionFlowKind, model: PermissionFlowModel, state: PermissionFlowGuideState,
    close: @escaping () -> Void
  ) {
    self.kind = kind
    self.model = model
    self.state = state
    self.close = close
  }

  private var text: PermissionFlowStrings { PermissionFlowStrings(model.language) }
  private var name: String { model.configuration.appName }
  private var draggable: Bool { kind.acceptsDraggedApp }
  private var tint: Color { state.success ? .green : kind.color }

  public var body: some View {
    HStack(spacing: 16) {
      tile
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          if !state.success && draggable {
            Image(systemName: "arrow.up")
              .font(.system(size: 13, weight: .bold))
              .symbolEffect(.bounce.up, options: .repeat(3), value: state.arrived)
          }
          Text(title).font(.system(size: 15, weight: .semibold))
        }
        .foregroundStyle(tint)
        Text(detail)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .id(state.success)
      .transition(.opacity.combined(with: .offset(y: 4)))
      Spacer(minLength: 0)
      if !state.success {
        Button(action: close) {
          Image(systemName: "xmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .background(.quaternary.opacity(0.6), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(text.dismissGuide)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .background(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(tint.opacity(0.07))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
    )
    .animation(
      reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.8), value: state.success)
  }

  @ViewBuilder private var tile: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(tint.opacity(0.10))
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          tint.opacity(0.55),
          style: StrokeStyle(lineWidth: 1.5, dash: state.success || !draggable ? [] : [5, 4]))
      if state.success {
        Image(systemName: "checkmark.seal.fill")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(.white, .green)
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      } else {
        ZStack(alignment: .bottomTrailing) {
          if draggable {
            PermissionFlowDragIcon(
              icon: model.configuration.icon, label: text.dragAccessibility(name, kind)
            )
            .frame(width: 52, height: 52)
          } else {
            Image(nsImage: model.configuration.icon).resizable().frame(width: 52, height: 52)
          }
          PermissionFlowBadge(kind: kind, size: 22)
            .offset(x: 6, y: 6)
            .allowsHitTesting(false)
        }
        .transition(.opacity)
      }
    }
    .frame(width: 76, height: 76)
  }

  private var title: String {
    if state.success { return text.accessGranted }
    return draggable ? text.dragTitle(name) : text.toggleTitle(name)
  }

  private var detail: String {
    if state.success { return text.returning(name) }
    return draggable ? text.dragDetail(kind) : text.toggleDetail(name, kind)
  }
}

struct PermissionFlowDragIcon: NSViewRepresentable {
  let icon: NSImage
  let label: String

  func makeNSView(context: Context) -> PermissionFlowDragImageView {
    let view = PermissionFlowDragImageView()
    view.image = icon
    view.imageScaling = .scaleProportionallyUpOrDown
    view.setAccessibilityLabel(label)
    return view
  }

  func updateNSView(_ view: PermissionFlowDragImageView, context: Context) {
    view.setAccessibilityLabel(label)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize, nsView: PermissionFlowDragImageView, context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? 52, height: proposal.height ?? 52)
  }
}

@MainActor
final class PermissionFlowDragImageView: NSImageView, NSDraggingSource {
  private var dragging = false

  override var intrinsicContentSize: NSSize { NSSize(width: 52, height: 52) }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func mouseDown(with event: NSEvent) {}

  override func mouseDragged(with event: NSEvent) {
    guard !dragging, let image else { return }
    let pasteboardItem = NSPasteboardItem()
    pasteboardItem.setString(Bundle.main.bundleURL.absoluteString, forType: .fileURL)
    let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
    item.setDraggingFrame(bounds, contents: image)
    dragging = true
    let session = beginDraggingSession(with: [item], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    .copy
  }

  func draggingSession(
    _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
  ) {
    dragging = false
  }
}

extension CGRect {
  fileprivate var coveredArea: CGFloat { isNull ? 0 : width * height }
}
