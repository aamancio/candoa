import AppKit
import SwiftUI

internal struct AskSettingsPane: View {
    @AppStorage(CandoaSettingsOption.askModel) private var model = CandoaAskPreferences.defaultModel
    @AppStorage(CandoaSettingsOption.askUsesPersonalOpenAIKey) private var usesPersonalOpenAIKey = false
    @State private var apiKey = ""
    @State private var hasSavedKey = CandoaAskKeychain.hasAPIKey
    @State private var keychainError: String?

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Ask")

                SettingsCard {
                    SettingsRow(
                        systemImage: "cpu",
                        title: "Model",
                        subtitle: "Use this model with your own OpenAI key. Candoa's hosted service manages its model on the server."
                    ) {
                        TextField("Model ID", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                    }

                    SettingsDivider()

                    SettingsToggleRow(
                        systemImage: "key.horizontal",
                        title: "Use your own OpenAI API key",
                        subtitle: "Keep your key in Keychain and send requests directly to OpenAI.",
                        isOn: $usesPersonalOpenAIKey
                    )
                }

                SettingsSectionTitle("Personal API Key")

                SettingsCard {
                    SettingsRow(
                        systemImage: "lock",
                        title: hasSavedKey ? "Replace saved key" : "Save an OpenAI API key",
                        subtitle: "Candoa stores only the key in this Mac's Keychain. It is never sent to Candoa."
                    ) {
                        HStack(spacing: 8) {
                            SecureField("sk-...", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 170)

                            Button(hasSavedKey ? "Replace" : "Save", action: saveAPIKey)
                                .controlSize(.small)
                                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if hasSavedKey {
                        SettingsDivider()

                        SettingsRow(
                            systemImage: "checkmark.shield",
                            title: "Personal key saved",
                            subtitle: "Ask can use your direct OpenAI connection whenever the option above is enabled."
                        ) {
                            Button("Remove", role: .destructive, action: removeAPIKey)
                                .controlSize(.small)
                        }
                    }

                    if let keychainError {
                        SettingsDivider()

                        Text(keychainError)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
    }

    private func saveAPIKey() {
        do {
            try CandoaAskKeychain.save(apiKey)
            apiKey = ""
            hasSavedKey = true
            usesPersonalOpenAIKey = true
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try CandoaAskKeychain.remove()
            hasSavedKey = false
            usesPersonalOpenAIKey = false
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }
}
