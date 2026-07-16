import AppKit
import SwiftUI

internal struct EliSettingsPane: View {
    @AppStorage(CandoaSettingsOption.askModel) private var model = CandoaEliPreferences.defaultModel
    @AppStorage(CandoaSettingsOption.askUsesPersonalOpenAIKey) private var usesPersonalOpenAIKey = false
    @State private var apiKey = ""
    @State private var hasSavedKey = CandoaEliKeychain.hasAPIKey
    @State private var keychainError: String?
    @StateObject private var accountController = CandoaAccountController()

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Eli")

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
                            subtitle: "Eli can use your direct OpenAI connection whenever the option above is enabled."
                        ) {
                            Button("Remove", role: .destructive, action: removeAPIKey)
                                .controlSize(.small)
                        }
                    }

                    if let keychainError {
                        SettingsDivider()

                        Text(keychainError)
                            .font(.callout)
                            .foregroundStyle(CandoaColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }

                SettingsSectionTitle("Candoa Subscription")

                SettingsCard {
                    if accountController.isSignedIn {
                        SettingsRow(
                            systemImage: accountController.hasActiveSubscription
                                ? "checkmark.seal"
                                : "person.crop.circle",
                            title: accountController.hasActiveSubscription
                                ? "Candoa \(accountController.status?.planID.capitalized ?? "")"
                                : "No active Candoa subscription",
                            subtitle: accountController.hasActiveSubscription
                                ? "Manage payment details, invoices, or your plan in Stripe."
                                : "Open Eli to subscribe to Candoa Pro."
                        ) {
                            if accountController.hasActiveSubscription {
                                Button("Manage", action: openBillingPortal)
                                    .controlSize(.small)
                                    .disabled(accountController.isWorking)
                            }
                        }

                        SettingsDivider()

                        SettingsRow(
                            systemImage: "rectangle.portrait.and.arrow.right",
                            title: "Candoa account",
                            subtitle: "This only removes the Candoa session from this Mac."
                        ) {
                            Button("Sign out", role: .destructive, action: accountController.signOut)
                                .controlSize(.small)
                        }
                    } else {
                        SettingsRow(
                            systemImage: "person.crop.circle.badge.questionmark",
                            title: "Not signed in",
                            subtitle: "Open Eli and continue with Apple to connect your subscription."
                        ) { }
                    }

                    if let accountError = accountController.errorMessage {
                        SettingsDivider()

                        Text(accountError)
                            .font(.callout)
                            .foregroundStyle(CandoaColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }
                }
            }
        }
        .task {
            await accountController.refresh()
        }
    }

    private func saveAPIKey() {
        do {
            try CandoaEliKeychain.save(apiKey)
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
            try CandoaEliKeychain.remove()
            hasSavedKey = false
            usesPersonalOpenAIKey = false
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func openBillingPortal() {
        Task { await accountController.openBillingPortal() }
    }
}
