// Vendored from PermissionFlow; edit the canonical package and re-vendor.
import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid
import Network

@MainActor
enum PermissionFlowProbe {
    static func status(_ kind: PermissionFlowKind, automationTarget: String?) -> PermissionFlowStatus {
        switch kind {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .denied
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .inputMonitoring:
            switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
            case kIOHIDAccessTypeGranted: return .granted
            case kIOHIDAccessTypeUnknown: return .notDetermined
            default: return .denied
            }
        case .fullDiskAccess:
            let path = NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db"
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else { return .denied }
            close(descriptor)
            return .granted
        case .automation:
            guard let automationTarget else { return .unknown }
            return automationStatus(target: automationTarget, ask: false)
        case .localNetwork:
            return .unknown
        }
    }

    static func request(
        _ kind: PermissionFlowKind, automationTarget: String?,
        completion: @escaping @MainActor () -> Void
    ) -> Bool {
        switch kind {
        case .microphone where status(kind, automationTarget: nil) == .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor in completion() }
            }
            return true
        case .automation:
            guard let target = automationTarget,
                status(kind, automationTarget: target) != .denied
            else { return false }
            launchQuietly(bundleIdentifier: target)
            Task.detached(priority: .userInitiated) {
                _ = PermissionFlowProbe.automationDetermination(target: target, ask: true)
                await MainActor.run { completion() }
            }
            return true
        case .localNetwork:
            LocalNetworkTrigger.shared.fire(completion: completion)
            return true
        default:
            return false
        }
    }

    private static func automationStatus(target: String, ask: Bool) -> PermissionFlowStatus {
        switch automationDetermination(target: target, ask: ask) {
        case noErr: return .granted
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .denied
        default: return .notDetermined
        }
    }

    nonisolated static func automationDetermination(target: String, ask: Bool) -> OSStatus {
        var descriptor = AEAddressDesc()
        let bytes = Array(target.utf8)
        let created = bytes.withUnsafeBufferPointer {
            AECreateDesc(typeApplicationBundleID, $0.baseAddress, $0.count, &descriptor)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&descriptor) }
        return AEDeterminePermissionToAutomateTarget(
            &descriptor, typeWildCard, typeWildCard, ask)
    }

    private static func launchQuietly(bundleIdentifier: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

@MainActor
private final class LocalNetworkTrigger {
    static let shared = LocalNetworkTrigger()
    private var browser: NWBrowser?

    func fire(completion: @escaping @MainActor () -> Void) {
        browser?.cancel()
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: NWParameters())
        self.browser = browser
        browser.start(queue: .main)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.browser?.cancel()
            self?.browser = nil
            completion()
        }
    }
}
