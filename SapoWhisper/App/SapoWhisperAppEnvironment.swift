//
//  SapoWhisperAppEnvironment.swift
//  SapoWhisper
//
//  Shared app-level objects used by AppKit and SwiftUI entry points.
//

import Foundation

@MainActor
final class SapoWhisperAppEnvironment {
    static let shared = SapoWhisperAppEnvironment()

    let viewModel = SapoWhisperViewModel()

    private init() {}
}
