//
//  AppDelegate.swift
//  SapoWhisper
//
//

import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Safety net: restaurar volumen del sistema si la app se cierra durante grabación
        AutoDuckingManager.shared.forceRestore()
    }
}
