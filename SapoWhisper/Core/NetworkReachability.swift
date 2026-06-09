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
final class NetworkReachability: ObservableObject {
    static let shared = NetworkReachability()

    /// Defaults to online so a slow first path update can never block dictation.
    @Published private(set) var isOnline = true

    var isOffline: Bool { !isOnline }

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            DispatchQueue.main.async {
                guard let self, self.isOnline != satisfied else { return }
                self.isOnline = satisfied
                SapoLog.lifecycle.info(
                    "Network path changed online=\(satisfied, privacy: .public)"
                )
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.sapowhisper.reachability", qos: .utility))
    }
}
