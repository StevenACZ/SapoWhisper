// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import Combine
import SwiftUI

@MainActor
public final class PermissionFlowModel: NSObject, ObservableObject {
  public let configuration: PermissionFlowConfiguration
  @Published public private(set) var statuses: [PermissionFlowKind: PermissionFlowStatus] = [:]
  @Published public private(set) var requested: Set<PermissionFlowKind> = []
  @Published public private(set) var guiding: PermissionFlowKind?
  @Published public private(set) var relaunchFailed = false
  @Published public private(set) var ready = false
  @Published public private(set) var relaunchPending = false
  public var onGranted: ((PermissionFlowKind) -> Void)?
  private var guide: PermissionFlowGuide?
  private var refreshTimer: Timer?
  private var guideDismissTimer: Timer?
  private var monitoring = false

  private static let completedKey = "permissionFlow.completed"
  private static let resumeKey = "permissionFlow.resume"
  private static let requestedKey = "permissionFlow.requested"

  public init(configuration: PermissionFlowConfiguration) {
    self.configuration = configuration
    super.init()
    requested = Set(
      (configuration.defaults.stringArray(forKey: Self.requestedKey) ?? [])
        .compactMap(PermissionFlowKind.init(rawValue:)))
    refresh()
  }

  public var language: PermissionFlowLanguage { configuration.language() }
  public var items: [PermissionFlowItem] { configuration.items }
  public var requiredItems: [PermissionFlowItem] { items.filter(\.required) }

  public func status(_ kind: PermissionFlowKind) -> PermissionFlowStatus {
    statuses[kind] ?? .unknown
  }

  public func isSatisfied(_ kind: PermissionFlowKind) -> Bool {
    switch status(kind) {
    case .granted: true
    case .unknown: requested.contains(kind)
    case .notDetermined, .denied: false
    }
  }

  public var allRequiredSatisfied: Bool { requiredItems.allSatisfy { isSatisfied($0.kind) } }
  public var satisfiedCount: Int { items.filter { isSatisfied($0.kind) }.count }
  public var next: PermissionFlowItem? {
    let pending = items.filter { !isSatisfied($0.kind) && isAvailable($0.kind) }
    return pending.first(where: \.required) ?? pending.first
  }

  public func isAvailable(_ kind: PermissionFlowKind) -> Bool {
    guard kind.mayRequireRelaunch else { return true }
    return items.allSatisfy {
      $0.kind == kind || !$0.required || $0.kind.order > kind.order || isSatisfied($0.kind)
    }
  }

  public func awaitingRelaunch(_ kind: PermissionFlowKind) -> Bool {
    kind.mayRequireRelaunch && requested.contains(kind) && !isSatisfied(kind)
  }

  public var isCompleted: Bool {
    configuration.defaults.bool(forKey: Self.completedKey)
      || configuration.legacyCompletionKeys.contains { configuration.defaults.bool(forKey: $0) }
  }

  public var isResuming: Bool { configuration.defaults.bool(forKey: Self.resumeKey) }

  public var shouldPresentAtLaunch: Bool {
    refresh()
    return !isCompleted || !ready || isResuming
  }

  public func markCompleted() {
    configuration.defaults.set(true, forKey: Self.completedKey)
    configuration.defaults.removeObject(forKey: Self.resumeKey)
  }

  @objc public func refresh() {
    var updated: [PermissionFlowKind: PermissionFlowStatus] = [:]
    for item in items {
      updated[item.kind] =
        item.status?()
        ?? PermissionFlowProbe.status(
          item.kind, automationTarget: configuration.automationTarget)
    }
    let newlyGranted = items.map(\.kind).filter {
      updated[$0] == .granted && statuses[$0] != nil && statuses[$0] != .granted
    }
    if updated != statuses { statuses = updated }
    let isReady = allRequiredSatisfied && (configuration.isReady?() ?? true)
    if ready != isReady { ready = isReady }
    let pending = !isReady && (configuration.pendingRelaunch?() ?? false)
    if relaunchPending != pending { relaunchPending = pending }
    for kind in newlyGranted { handleGranted(kind) }
  }

  public func request(_ kind: PermissionFlowKind, from sourceFrame: CGRect? = nil) {
    guard let item = items.first(where: { $0.kind == kind }), isAvailable(kind) else { return }
    markRequested(kind)
    dismissGuide()
    if let custom = item.request {
      custom { [weak self] in self?.refresh() }
      return
    }
    if PermissionFlowProbe.request(
      kind, automationTarget: configuration.automationTarget,
      completion: { [weak self] in self?.afterSystemPrompt() })
    {
      return
    }
    openSettings(kind, from: sourceFrame)
  }

  public func openSettings(_ kind: PermissionFlowKind, from sourceFrame: CGRect? = nil) {
    if kind.mayRequireRelaunch { configuration.defaults.set(true, forKey: Self.resumeKey) }
    guiding = kind
    let guide = PermissionFlowGuide(
      kind: kind, model: self, sourceFrame: sourceFrame,
      close: { [weak self] in self?.dismissGuide() })
    self.guide = guide
    guide.start()
    if let url = kind.settingsURL { NSWorkspace.shared.open(url) }
    startMonitoring()
  }

  public func dismissGuide() {
    guideDismissTimer?.invalidate()
    guideDismissTimer = nil
    guide?.stop()
    guide = nil
    guiding = nil
  }

  public func startMonitoring() {
    guard !monitoring else { return }
    monitoring = true
    refreshTimer = Timer.scheduledTimer(
      timeInterval: 0.5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(refresh),
      name: NSWorkspace.didActivateApplicationNotification, object: nil)
  }

  public func stopMonitoring() {
    monitoring = false
    refreshTimer?.invalidate()
    refreshTimer = nil
    NSWorkspace.shared.notificationCenter.removeObserver(self)
    if guideDismissTimer == nil { dismissGuide() }
  }

  public func relaunch() {
    guard Bundle.main.bundleURL.pathExtension == "app" else {
      relaunchFailed = true
      return
    }
    configuration.defaults.set(true, forKey: Self.resumeKey)
    configuration.defaults.synchronize()
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
    helper.arguments = [
      "-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
      "permission-flow-relaunch", String(ProcessInfo.processInfo.processIdentifier),
      Bundle.main.bundleURL.path,
    ]
    helper.standardInput = FileHandle.nullDevice
    helper.standardOutput = FileHandle.nullDevice
    helper.standardError = FileHandle.nullDevice
    do {
      try helper.run()
      NSApp.terminate(nil)
    } catch {
      relaunchFailed = true
    }
  }

  private func markRequested(_ kind: PermissionFlowKind) {
    requested.insert(kind)
    configuration.defaults.set(requested.map(\.rawValue).sorted(), forKey: Self.requestedKey)
  }

  private func afterSystemPrompt() {
    refresh()
    NSApp.activate()
  }

  private func handleGranted(_ kind: PermissionFlowKind) {
    onGranted?(kind)
    guard guiding == kind, let guide else { return }
    guide.showSuccess()
    guideDismissTimer?.invalidate()
    guideDismissTimer = Timer.scheduledTimer(
      timeInterval: 1.2, target: self, selector: #selector(finishGuide), userInfo: nil,
      repeats: false)
  }

  @objc private func finishGuide() {
    dismissGuide()
    NSApp.activate()
  }
}
