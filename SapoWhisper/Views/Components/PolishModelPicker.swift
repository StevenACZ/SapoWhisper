//
//  PolishModelPicker.swift
//  SapoWhisper
//
//  Model selector for the AI polish provider: free text so any model ID works
//  (OpenRouter alone lists hundreds — qwen, deepseek, llama, ...), plus a
//  suggestions menu when the endpoint has a curated catalog.
//

import SwiftUI

struct PolishModelPicker: View {
    let endpoint: PolishEndpoint
    @Binding var model: String

    var body: some View {
        HStack(spacing: 6) {
            TextField("ai.provider.model_placeholder".localized, text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            if !endpoint.suggestedModels.isEmpty {
                Menu {
                    ForEach(endpoint.suggestedModels, id: \.self) { suggestion in
                        Button {
                            model = suggestion
                        } label: {
                            if suggestion == model.trimmingCharacters(in: .whitespacesAndNewlines) {
                                Label(suggestion, systemImage: "checkmark")
                            } else {
                                Text(suggestion)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
                .help("ai.provider.model_suggestions_help".localized)
            }
        }
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
