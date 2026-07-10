//
//  NetworkReachability.swift
//  SapoWhisper
//

import Combine
import Foundation
import Network
import os

/// R7: tracks network path availability so cloud engines can fail fast with a
/// clear `.network` error instead of riding their full request timeout, and so
/// the menu bar can hint at the offline state. Local engines are unaffected.
///
/// Concurrency: `NWPathMonitor` invokes its update handler on the private
/// utility queue, so the handler path is `nonisolated` and hops to the main
/// actor before touching the published flag — the same pattern as
/// `AudioDeviceManager.publishAvailableDevices`.
final class NetworkReachability: ObservableObject, @unchecked Sendable {
    nonisolated static let shared = NetworkReachability()

    /// Defaults to online so a slow first path update can never block dictation.
    @Published private(set) var isOnline = true

    var isOffline: Bool { !isOnline }

    private nonisolated let monitor = NWPathMonitor()

    private nonisolated init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publishOnlineState(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "com.sapowhisper.reachability", qos: .utility))
    }

    private nonisolated func publishOnlineState(_ satisfied: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isOnline != satisfied else { return }
                self.isOnline = satisfied
                SapoLog.lifecycle.info(
                    "Network path changed online=\(satisfied, privacy: .public)"
                )
            }
        }
    }
}
