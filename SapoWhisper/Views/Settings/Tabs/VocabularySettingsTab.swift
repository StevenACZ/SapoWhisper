//
//  VocabularySettingsTab.swift
//  SapoWhisper
//

import SwiftUI

struct VocabularySettingsTab: View {
    var body: some View {
        ScrollView {
            VocabularySettingsCard()
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(16)
        }
    }
}

#Preview("Vocabulary Settings") {
    VocabularySettingsTab()
        .frame(width: 780, height: 560)
}
