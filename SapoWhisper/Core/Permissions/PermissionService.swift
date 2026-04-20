//
//  PermissionService.swift
//  SapoWhisper
//
//  Centralizes permission checks and the guided onboarding flow.
//

import AppKit

@MainActor
final class PermissionService {
    static let shared = PermissionService()

    private init() {}

    func isGranted(_ permission: AppPermission) -> Bool {
        permission.isGranted()
    }

    func missingPermissions() -> [AppPermission] {
        AppPermission.allCases.filter { !isGranted($0) }
    }

    func recordingBlockingPermissions(for engine: TranscriptionEngine) -> [AppPermission] {
        var permissions: [AppPermission] = [.microphone]

        if engine == .appleOnline {
            permissions.append(.speechRecognition)
        }

        return permissions
    }

    func missingRecordingPermissions(for engine: TranscriptionEngine) -> [AppPermission] {
        recordingBlockingPermissions(for: engine).filter { !isGranted($0) }
    }

    func requestInteractively(_ permission: AppPermission, sourceFrameInScreen: CGRect? = nil) {
        guard !permission.isGranted() else { return }

        let sourceFrame = sourceFrameInScreen ?? Self.mouseSourceRect()
        Task { @MainActor in
            let primingResult = await permission.primeSystemAccessIfNeeded()

            guard !permission.isGranted() else { return }

            switch primingResult {
            case .granted:
                return
            case .needsSystemSettings, .skipped:
                PermissionAssistant.shared.present(
                    permission: permission,
                    sourceFrameInScreen: sourceFrame
                )
            }
        }
    }

    func showRequirementsWindow(force: Bool = false) {
        PermissionRequirementsWindowController.shared.showWindow(force: force)
    }

    private static func mouseSourceRect() -> CGRect {
        let point = NSEvent.mouseLocation
        return CGRect(x: point.x - 36, y: point.y - 20, width: 72, height: 40)
    }
}
