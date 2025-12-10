//
//  AboutSettingsTab.swift
//  SapoWhisper
//
//  Created by Steven on 9/12/24.
//

import SwiftUI

/// Tab de información sobre la aplicación
struct AboutSettingsTab: View {
    @State private var tapCount = 0
    @State private var showLoadingIcon = false
    @State private var iconBounce = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                heroSection
                howToSection
                privacySection
                permissionsSection
                creditsSection
            }
            .padding()
        }
    }
    
    // MARK: - Hero Section
    
    private var heroSection: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.sapoGreen.opacity(0.3), Color.sapoGreen.opacity(0.1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 90, height: 90)
                
                // Easter egg: 3 clics cambia el icono
                Group {
                    if showLoadingIcon, let loadingIcon = NSImage(named: "DockIconLoading") {
                        Image(nsImage: loadingIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .scaleEffect(iconBounce ? 1.2 : 1.0)
                .animation(.interpolatingSpring(stiffness: 300, damping: 10), value: iconBounce)
                .onTapGesture {
                    handleIconTap()
                }
            }
            
            VStack(spacing: 4) {
                Text("app_name".localized)
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("v\(Constants.appVersion)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text("config.subtitle_info".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }
    
    // MARK: - Easter Egg Handler
    
    private func handleIconTap() {
        tapCount += 1
        
        if tapCount >= 3 {
            // Activar easter egg
            tapCount = 0
            
            // Efecto de rebote al cambiar
            withAnimation {
                iconBounce = true
                showLoadingIcon = true
            }
            
            // Quitar el rebote después de la animación
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                iconBounce = false
            }
            
            // Volver al icono normal después de 3 segundos
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                withAnimation {
                    iconBounce = true
                }
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    showLoadingIcon = false
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        iconBounce = false
                    }
                }
            }
        }
        
        // Reset del contador después de 1 segundo sin clics
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if tapCount > 0 && tapCount < 3 {
                tapCount = 0
            }
        }
    }
    
    // MARK: - How To Section
    
    private var howToSection: some View {
        InfoSection(
            icon: "questionmark.circle.fill",
            title: "info.how_to_title".localized,
            content: "info.how_to_body".localized
        )
    }
    
    // MARK: - Privacy Section
    
    private var privacySection: some View {
        InfoSection(
            icon: "lock.shield.fill",
            title: "info.privacy_title".localized,
            content: "info.privacy_body".localized
        )
    }
    
    // MARK: - Permissions Section
    
    private var permissionsSection: some View {
        InfoSection(
            icon: "hand.raised.fill",
            title: "info.permissions_title".localized,
            content: "info.permissions_body".localized
        )
    }
    
    // MARK: - Credits Section
    
    private var creditsSection: some View {
        VStack(spacing: 8) {
            Divider()
                .frame(width: 200)
            
            VStack(spacing: 8) {
                Text("made_by".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button {
                    if let url = URL(string: Constants.githubURL) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("settings.view_github".localized, systemImage: "link")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }
}

#Preview {
    AboutSettingsTab()
        .frame(width: 480, height: 500)
}
