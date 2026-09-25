// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AppKit
import SwiftUI

public enum PermissionFlowKind: String, CaseIterable, Sendable {
    case accessibility
    case fullDiskAccess
    case automation
    case microphone
    case localNetwork
    case inputMonitoring
    case screenRecording

    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .accessibility: .systemBlue
        case .fullDiskAccess: .systemBrown
        case .automation: .systemPink
        case .microphone: .systemOrange
        case .localNetwork: .systemCyan
        case .inputMonitoring: .systemPurple
        case .screenRecording: .systemRed
        }
    }

    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .fullDiskAccess: "externaldrive.fill"
        case .automation: "gearshape.2.fill"
        case .microphone: "mic.fill"
        case .localNetwork: "network"
        case .inputMonitoring: "keyboard.fill"
        case .screenRecording: "rectangle.dashed.badge.record"
        }
    }

    var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .automation: "Privacy_Automation"
        case .microphone: "Privacy_Microphone"
        case .localNetwork: "Privacy_LocalNetwork"
        case .inputMonitoring: "Privacy_ListenEvent"
        case .screenRecording: "Privacy_ScreenCapture"
        }
    }

    var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")
    }

    var acceptsDraggedApp: Bool {
        switch self {
        case .accessibility, .fullDiskAccess, .inputMonitoring, .screenRecording: true
        case .automation, .microphone, .localNetwork: false
        }
    }

    var mayRequireRelaunch: Bool { self == .screenRecording || self == .inputMonitoring }
}

public enum PermissionFlowStatus: Equatable, Sendable {
    case granted
    case notDetermined
    case denied
    case unknown
}

public enum PermissionFlowLanguage: Sendable {
    case english
    case spanish

    public static var system: PermissionFlowLanguage {
        Locale.preferredLanguages.first?.hasPrefix("es") == true ? .spanish : .english
    }
}

public struct PermissionFlowText: Sendable, Equatable {
    public let english: String
    public let spanish: String

    public init(_ english: String, _ spanish: String) {
        self.english = english
        self.spanish = spanish
    }

    public func resolve(_ language: PermissionFlowLanguage) -> String {
        language == .spanish ? spanish : english
    }
}

public struct PermissionFlowItem: Identifiable {
    public let kind: PermissionFlowKind
    public var reason: PermissionFlowText
    public var required: Bool
    public var status: (@MainActor () -> PermissionFlowStatus)?
    public var request: (@MainActor (@escaping @MainActor () -> Void) -> Void)?

    public var id: PermissionFlowKind { kind }

    public init(
        _ kind: PermissionFlowKind,
        reason: PermissionFlowText,
        required: Bool = true,
        status: (@MainActor () -> PermissionFlowStatus)? = nil,
        request: (@MainActor (@escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.kind = kind
        self.reason = reason
        self.required = required
        self.status = status
        self.request = request
    }
}

public struct PermissionFlowConfiguration {
    public var appName: String
    public var icon: NSImage
    public var accent: Color
    public var items: [PermissionFlowItem]
    public var defaults: UserDefaults
    public var language: @MainActor () -> PermissionFlowLanguage
    public var tagline: PermissionFlowText?
    public var welcomeDuration: TimeInterval
    public var legacyCompletionKeys: [String]
    public var automationTarget: String?
    public var note: PermissionFlowText?
    public var isReady: (@MainActor () -> Bool)?
    public var pendingRelaunch: (@MainActor () -> Bool)?
    public var menuBarAnchor: (@MainActor () -> CGRect?)?

    @MainActor
    public init(
        appName: String,
        icon: NSImage? = nil,
        accent: Color = .accentColor,
        items: [PermissionFlowItem],
        defaults: UserDefaults = .standard,
        language: @escaping @MainActor () -> PermissionFlowLanguage = { .system },
        tagline: PermissionFlowText? = nil,
        welcomeDuration: TimeInterval = 3.5,
        legacyCompletionKeys: [String] = [],
        automationTarget: String? = nil,
        note: PermissionFlowText? = nil,
        isReady: (@MainActor () -> Bool)? = nil,
        pendingRelaunch: (@MainActor () -> Bool)? = nil,
        menuBarAnchor: (@MainActor () -> CGRect?)? = nil
    ) {
        self.appName = appName
        self.icon = icon ?? NSApplication.shared.applicationIconImage
        self.accent = accent
        self.items = items.sorted { $0.kind.order < $1.kind.order }
        self.defaults = defaults
        self.language = language
        self.tagline = tagline
        self.welcomeDuration = welcomeDuration
        self.legacyCompletionKeys = legacyCompletionKeys
        self.automationTarget = automationTarget
        self.note = note
        self.isReady = isReady
        self.pendingRelaunch = pendingRelaunch
        self.menuBarAnchor = menuBarAnchor
    }
}
