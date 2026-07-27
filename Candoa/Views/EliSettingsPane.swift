import AppKit
import SwiftUI

internal struct EliSettingsPane: View {
    @AppStorage(CandoaSettingsOption.askModel) private var model = CandoaEliPreferences.defaultModel
    @AppStorage(CandoaSettingsOption.askUsesPersonalOpenAIKey) private var usesPersonalOpenAIKey = false
    @State private var apiKey = ""
    @State private var hasSavedKey = CandoaEliKeychain.hasAPIKey
    @State private var keychainError: String?
    @EnvironmentObject private var userStore: UserStore

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
                                .candoaButton(.secondary)
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
                                .candoaButton(.secondary)
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
                    SettingsRow(
                        systemImage: userStore.hasActiveSubscription
                            ? "checkmark.seal"
                            : "person.crop.circle",
                        title: userStore.hasActiveSubscription
                            ? "Candoa \(userStore.status?.planID.capitalized ?? "")"
                            : "No active Candoa subscription",
                        subtitle: userStore.hasActiveSubscription
                            ? "Manage payment details, invoices, or your plan in Stripe."
                            : "Open Eli to subscribe to Candoa Pro."
                    ) {
                        if userStore.hasActiveSubscription {
                            Button("Manage", action: openBillingPortal)
                                .candoaButton(.secondary)
                                .controlSize(.small)
                                .disabled(userStore.isWorking)
                        }
                    }

                    SettingsDivider()

                    SettingsRow(
                        systemImage: userStore.status?.hasPasskey == true
                            ? "key.fill"
                            : "laptopcomputer",
                        title: userStore.status?.hasPasskey == true
                            ? "Passkey ready"
                            : "Subscription access on this Mac",
                        subtitle: userStore.status?.hasPasskey == true
                            ? "Use your passkey for subscriptions and hosted services on another Mac."
                            : "Create a passkey to use subscriptions and hosted services on another Mac."
                    ) {
                        if userStore.status?.hasPasskey != true {
                            Button("Create Passkey") {
                                userStore.createPasskey()
                            }
                            .candoaButton(.secondary)
                            .controlSize(.small)
                            .disabled(userStore.isWorking)
                        }
                    }

                    if !userStore.isSignedIn {
                        SettingsDivider()

                        SettingsRow(
                            systemImage: "person.crop.circle.badge.checkmark",
                            title: "Use an existing account",
                            subtitle: "Sign in to subscriptions and hosted services with your passkey."
                        ) {
                            Button(
                                userStore.isSigningInWithPasskey ? "Signing In…" : "Sign In"
                            ) {
                                userStore.signInWithPasskey()
                            }
                            .candoaButton(.secondary)
                            .controlSize(.small)
                            .disabled(userStore.isWorking)
                        }
                    }

                    if let accountMessage = userStore.accountMessage {
                        SettingsDivider()

                        Text(accountMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                    }

                    if let accountError = userStore.errorMessage {
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
            await userStore.refresh()
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
        Task { await userStore.openBillingPortal() }
    }
}
