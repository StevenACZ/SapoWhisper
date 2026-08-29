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
    var defaults: UserDefaults = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                TextField("ai.provider.model_placeholder".localized, text: $model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))

                let suggestions = endpoint.modelRecommendations.filter(\.isSuggested)
                if !suggestions.isEmpty {
                    Menu {
                        Section("ai.provider.model_ranking_header".localized) {
                            ForEach(suggestions) { recommendation in
                                Button {
                                    model = recommendation.model
                                    applyBenchmarkedReasoning(for: recommendation)
                                } label: {
                                    let title =
                                        "\(recommendation.tier.displayName) · \(recommendation.model)"
                                    if recommendation.model
                                        == model.trimmingCharacters(in: .whitespacesAndNewlines)
                                    {
                                        Label(title, systemImage: "checkmark")
                                    } else {
                                        Text(title)
                                    }
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
                    .accessibilityLabel("ai.provider.model_recommendations".localized)
                }
            }

            if let recommendation = endpoint.modelRecommendation(for: model) {
                VStack(alignment: .leading, spacing: 2) {
                    Label {
                        Text(recommendation.tier.displayName)
                    } icon: {
                        Image(systemName: recommendationIcon(for: recommendation.tier))
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(recommendationColor(for: recommendation.tier))

                    Text(recommendation.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if recommendation.tier.carriesFidelityRisk {
                        Text("ai.provider.model_risk_note".localized)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if endpoint == .localServer {
                Label("ai.provider.model_local_experimental".localized, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("ai.provider.model_untested_note".localized)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Picking a ranked model also restores the reasoning budget its published
    /// numbers were measured with; free-text IDs never touch the setting.
    private func applyBenchmarkedReasoning(for recommendation: PolishModelRecommendation) {
        let policy = PolishModelCatalog.reasoningPolicy(for: recommendation.model, provider: endpoint)
        let effort = policy.benchmarked.coerced(toMinimum: policy.minimum)
        defaults.set(effort.rawValue, forKey: Constants.StorageKeys.aiPolishReasoningEffort)
    }

    private func recommendationIcon(for tier: PolishModelEvidenceTier) -> String {
        switch tier {
        case .bestTested: return "checkmark.seal.fill"
        case .bestValue: return "star.circle.fill"
        case .sameLanguageValue: return "equal.circle.fill"
        case .fastBudget: return "bolt.circle.fill"
        case .economy: return "dollarsign.circle.fill"
        case .notRecommended: return "xmark.octagon.fill"
        }
    }

    private func recommendationColor(for tier: PolishModelEvidenceTier) -> Color {
        switch tier {
        case .bestTested: return .sapoGreenText
        case .bestValue: return .teal
        case .sameLanguageValue: return .blue
        case .fastBudget: return .orange
        case .economy: return .secondary
        case .notRecommended: return .sapoError
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
