//
//  PolishModelPicker.swift
//  SapoWhisper
//
//  Model selector for the AI polish provider: a fixed menu when the endpoint
//  has a curated catalog, free text otherwise (Groq/custom catalogs rotate).
//

import SwiftUI

struct PolishModelPicker: View {
    let endpoint: PolishEndpoint
    @Binding var model: String

    var body: some View {
        if endpoint.suggestedModels.isEmpty {
            TextField("ai.provider.model_placeholder".localized, text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
        } else {
            Picker("ai.provider.model".localized, selection: $model) {
                ForEach(choices, id: \.self) { choice in
                    Text(choice).tag(choice)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Catalog plus the saved value when it is off-catalog, so a previously
    /// typed model never changes silently.
    private var choices: [String] {
        let suggested = endpoint.suggestedModels
        let current = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty && !suggested.contains(current) {
            return [current] + suggested
        }
        return suggested
    }
}

#Preview("Polish Model Picker") {
    VStack(spacing: 12) {
        PolishModelPicker(endpoint: .openRouter, model: .constant("openai/gpt-5.4-nano"))
        PolishModelPicker(endpoint: .custom, model: .constant("llama3.1"))
    }
    .padding()
    .frame(width: 320)
}
