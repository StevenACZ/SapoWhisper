//
//  PasteDelivery.swift
//  SapoWhisper
//

import Foundation

/// Seam over `PasteManager`'s statics so delivery flows can be driven by a
/// spy in tests.
@MainActor
protocol PasteDelivering {
    func savePreviousApp()
    func copyToClipboard(_ text: String)
    func simulatePaste(onPasted: (@MainActor () -> Void)?)
}

struct SystemPasteDelivery: PasteDelivering {
    func savePreviousApp() {
        PasteManager.savePreviousApp()
    }

    func copyToClipboard(_ text: String) {
        PasteManager.copyToClipboard(text)
    }

    func simulatePaste(onPasted: (@MainActor () -> Void)?) {
        PasteManager.simulatePaste(onPasted: onPasted)
    }
}
