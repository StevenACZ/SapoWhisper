//
//  AppDelegate.swift
//  SapoWhisper
//
//  Created by Steven on 8/12/24.
//

import SwiftUI
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configurar la app para que no aparezca en el Dock
        NSApp.setActivationPolicy(.accessory)
        
        // Solicitar permisos de micrófono al inicio
        requestMicrophonePermission()
    }
    
    private func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                print("✅ Permiso de micrófono concedido")
            } else {
                print("❌ Permiso de micrófono denegado")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup si es necesario
    }
}
