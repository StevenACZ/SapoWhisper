import SwiftUI

struct VocabularySettingsCard: View {
    @ObservedObject private var vocabularyManager = VocabularyManager.shared

    @State private var newKeyterm = ""
    @State private var newReplaceFrom = ""
    @State private var newReplaceTo = ""

    var body: some View {
        SettingsCard(icon: "text.book.closed", title: "config.vocabulary".localized) {
            VStack(alignment: .leading, spacing: 16) {
                keytermsSection
                Divider()
                replacementsSection
            }
        }
    }

    private var keytermsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.keyterms".localized)
                .font(.subheadline.weight(.medium))

            ForEach(Array(vocabularyManager.keyterms.enumerated()), id: \.offset) { index, term in
                HStack {
                    Text(term)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button(action: { vocabularyManager.removeKeyterm(at: index) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("config.keyterm_placeholder".localized, text: $newKeyterm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit { addKeyterm() }

                Button("config.add".localized) { addKeyterm() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(newKeyterm.isEmpty)
            }

            Text("config.keyterms_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var replacementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("config.replacements".localized)
                .font(.subheadline.weight(.medium))

            ForEach(Array(vocabularyManager.replacements.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                HStack {
                    Text("\(key)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button(action: { vocabularyManager.removeReplacement(forKey: key) }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }

            HStack(spacing: 8) {
                TextField("config.replace_from".localized, text: $newReplaceFrom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(maxWidth: 120)

                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("config.replace_to".localized, text: $newReplaceTo)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button("config.add".localized) { addReplacement() }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    .disabled(newReplaceFrom.isEmpty || newReplaceTo.isEmpty)
            }

            Text("config.replacements_desc".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func addKeyterm() {
        vocabularyManager.addKeyterm(newKeyterm)
        newKeyterm = ""
    }

    private func addReplacement() {
        vocabularyManager.addReplacement(from: newReplaceFrom, to: newReplaceTo)
        newReplaceFrom = ""
        newReplaceTo = ""
    }
}
