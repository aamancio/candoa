import AppKit
import SwiftUI

internal struct EliSettingsPane: View {
    @State private var connection = CandoaEliPreferences.connection
    @State private var hostedModelID = CandoaEliPreferences.hostedModelID ?? ""
    @State private var directModelID = CandoaEliPreferences.directModel.id
    @State private var reasoningEffort = CandoaEliPreferences.reasoningEffort
    @State private var apiKey = ""
    @State private var savedKeyProviders = Set(
        CandoaAIProvider.allCases.filter(CandoaEliKeychain.hasAPIKey(for:))
    )
    @State private var keychainError: String?
    @EnvironmentObject private var userStore: UserStore

    /// UI-test launches share the real defaults domain, so persistence is
    /// suspended there; selections live in view state and launch-argument
    /// overrides only.
    private static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
    }

    private var directModel: CandoaAIModel {
        CandoaAIModelCatalog.model(forID: directModelID)
            ?? CandoaAIModelCatalog.directModels[0]
    }

    private var selectedProvider: CandoaAIProvider { directModel.provider }

    private var connectionOptions: [SettingsPickerOption] {
        var connections: [CandoaEliConnection] = [.candoaCloud, .personalKey]
#if DEBUG
        if CandoaAIProvider.allCases.contains(where: {
            CandoaEliPreferences.environmentAPIKey(for: $0) != nil
        }) || connection == .environment {
            connections.append(.environment)
        }
#endif
        return connections.map { SettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
    }

    private var providerOptions: [SettingsPickerOption] {
        let providers: [CandoaAIProvider]
        if connection == .environment {
            let available = CandoaAIProvider.allCases.filter {
                CandoaEliPreferences.environmentAPIKey(for: $0) != nil
            }
            providers = available.isEmpty ? CandoaAIProvider.allCases : available
        } else {
            providers = CandoaAIProvider.allCases
        }
        return providers.map { SettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
    }

    private var directModelOptions: [SettingsPickerOption] {
        CandoaAIModelCatalog.directModels(for: selectedProvider).map {
            SettingsPickerOption(id: $0.id, title: $0.displayName)
        }
    }

    private var hostedModelOptions: [SettingsPickerOption] {
        [SettingsPickerOption(id: "", title: "Automatic")]
            + userStore.hostedModels.map {
                SettingsPickerOption(id: $0.id, title: $0.displayName)
            }
    }

    private var reasoningOptions: [SettingsPickerOption] {
        let efforts = connection == .candoaCloud
            ? CandoaAIReasoningEffort.allCases
            : directModel.supportedEfforts
        return efforts.map { SettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
    }

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionTitle("Eli")

                SettingsCard {
                    SettingsPickerRow(
                        systemImage: "point.3.connected.trianglepath.dotted",
                        title: "Connection",
                        subtitle: connection == .candoaCloud
                            ? "Use your Candoa subscription with server-managed credentials."
                            : "Send requests directly from this Mac to the selected provider.",
                        selection: connectionBinding,
                        options: connectionOptions
                    )

                    SettingsDivider()

                    if connection == .candoaCloud {
                        SettingsPickerRow(
                            systemImage: "cpu",
                            title: "Model",
                            subtitle: userStore.hostedModels.isEmpty
                                ? "Automatic uses your plan's default model. Sign in to choose from your plan's models."
                                : "Models available on your Candoa plan.",
                            selection: hostedModelBinding,
                            options: hostedModelOptions
                        )
                    } else {
                        SettingsPickerRow(
                            systemImage: "building.2",
                            title: "Provider",
                            subtitle: "Direct requests use this provider's API with your own credentials.",
                            selection: providerBinding,
                            options: providerOptions
                        )

                        SettingsDivider()

                        SettingsPickerRow(
                            systemImage: "cpu",
                            title: "Model",
                            subtitle: "Curated current models for \(selectedProvider.displayName).",
                            selection: directModelBinding,
                            options: directModelOptions
                        )
                    }

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "brain",
                        title: "Reasoning",
                        subtitle: "How much the model thinks before answering. Low is fastest.",
                        selection: reasoningBinding,
                        options: reasoningOptions
                    )
                }

                if connection == .personalKey {
                    personalKeySection
                }

#if DEBUG
                if connection == .environment {
                    environmentSection
                }
#endif

                subscriptionSection
            }
        }
        .task {
            normalizeSelections()
            await userStore.refresh()
            await userStore.refreshHostedModels()
        }
    }

    private var personalKeySection: some View {
        Group {
            SettingsSectionTitle("Personal API Key")

            SettingsCard {
                SettingsRow(
                    systemImage: "lock",
                    title: savedKeyProviders.contains(selectedProvider)
                        ? "Replace your \(selectedProvider.displayName) key"
                        : "Save a \(selectedProvider.displayName) API key",
                    subtitle: "Candoa stores one key per provider in this Mac's Keychain. Keys are never sent to Candoa."
                ) {
                    HStack(spacing: 8) {
                        SecureField(selectedProvider.keyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)

                        Button(
                            savedKeyProviders.contains(selectedProvider) ? "Replace" : "Save",
                            action: saveAPIKey
                        )
                        .candoaButton(.secondary)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if savedKeyProviders.contains(selectedProvider) {
                    SettingsDivider()

                    SettingsRow(
                        systemImage: "checkmark.shield",
                        title: "\(selectedProvider.displayName) key saved",
                        subtitle: "Eli sends direct requests with this key while \(selectedProvider.displayName) is selected."
                    ) {
                        Button("Remove", role: .destructive, action: removeAPIKey)
                            .candoaButton(.secondary)
                            .controlSize(.small)
                    }
                } else {
                    SettingsDivider()

                    SettingsRow(
                        systemImage: "exclamationmark.triangle",
                        title: "No \(selectedProvider.displayName) key on this Mac",
                        subtitle: "Eli can't use the direct \(selectedProvider.displayName) connection until you save a key."
                    ) {
                        EmptyView()
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
        }
    }

#if DEBUG
    private var environmentSection: some View {
        Group {
            SettingsSectionTitle("Environment Credentials")

            SettingsCard {
                SettingsRow(
                    systemImage: CandoaEliPreferences.environmentAPIKey(for: selectedProvider) != nil
                        ? "checkmark.shield"
                        : "exclamationmark.triangle",
                    title: CandoaEliPreferences.environmentAPIKey(for: selectedProvider) != nil
                        ? "\(selectedProvider.environmentVariable) is set"
                        : "\(selectedProvider.environmentVariable) is not set",
                    subtitle: "Debug builds only: reads the provider key from this process's environment."
                ) {
                    EmptyView()
                }
            }
        }
    }
#endif

    private var subscriptionSection: some View {
        Group {
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
                    systemImage: userStore.status?.hasAppleAccount == true
                        ? "checkmark.circle.fill"
                        : "apple.logo",
                    title: userStore.status?.hasAppleAccount == true
                        ? "Signed in with Apple"
                        : "Restore your Candoa account",
                    subtitle: userStore.status?.hasAppleAccount == true
                        ? "Subscriptions and hosted services follow your Apple-linked Candoa account."
                        : "Sign in with Apple to use your subscription on this or another Mac."
                ) {
                    if userStore.status?.hasAppleAccount != true {
                        Button(
                            userStore.isSigningInWithApple
                                ? "Signing In…"
                                : "Sign In with Apple"
                        ) {
                            userStore.signInWithApple()
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

    private var connectionBinding: Binding<String> {
        Binding(
            get: { connection.rawValue },
            set: { newValue in
                guard let newConnection = CandoaEliConnection(rawValue: newValue) else { return }
                connection = newConnection
                if !Self.isUITesting {
                    CandoaEliPreferences.setConnection(newConnection)
                }
                coerceReasoningEffort()
            }
        )
    }

    private var hostedModelBinding: Binding<String> {
        Binding(
            get: { hostedModelID },
            set: { newValue in
                hostedModelID = newValue
                persist(newValue, forKey: CandoaSettingsOption.askHostedModel)
            }
        )
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { selectedProvider.rawValue },
            set: { newValue in
                guard let provider = CandoaAIProvider(rawValue: newValue),
                      provider != selectedProvider else { return }
                setDirectModel(CandoaAIModelCatalog.directDefaultModel(for: provider).id)
            }
        )
    }

    private var directModelBinding: Binding<String> {
        Binding(
            get: { directModelID },
            set: { newValue in setDirectModel(newValue) }
        )
    }

    private var reasoningBinding: Binding<String> {
        Binding(
            get: { reasoningEffort.rawValue },
            set: { newValue in
                guard let effort = CandoaAIReasoningEffort(rawValue: newValue) else { return }
                reasoningEffort = effort
                persist(effort.rawValue, forKey: CandoaSettingsOption.askReasoningEffort)
            }
        )
    }

    private func setDirectModel(_ modelID: String) {
        guard CandoaAIModelCatalog.model(forID: modelID) != nil else { return }
        directModelID = modelID
        persist(modelID, forKey: CandoaSettingsOption.askDirectModel)
        apiKey = ""
        keychainError = nil
        coerceReasoningEffort()
    }

    /// Coerces stale stored IDs back into the catalog and persists the
    /// resolved selection, mirroring normalizeDefaultSearchProvider().
    private func normalizeSelections() {
        if !Self.isUITesting {
            CandoaEliPreferences.setConnection(connection)
            persist(directModelID, forKey: CandoaSettingsOption.askDirectModel)
            persist(reasoningEffort.rawValue, forKey: CandoaSettingsOption.askReasoningEffort)
        }
        coerceReasoningEffort()
    }

    private func coerceReasoningEffort() {
        guard connection != .candoaCloud else { return }
        let clamped = directModel.clampedEffort(reasoningEffort)
        if clamped != reasoningEffort {
            reasoningEffort = clamped
            persist(clamped.rawValue, forKey: CandoaSettingsOption.askReasoningEffort)
        }
    }

    private func persist(_ value: String, forKey key: String) {
        guard !Self.isUITesting else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveAPIKey() {
        do {
            try CandoaEliKeychain.save(apiKey, for: selectedProvider)
            apiKey = ""
            savedKeyProviders.insert(selectedProvider)
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try CandoaEliKeychain.remove(for: selectedProvider)
            savedKeyProviders.remove(selectedProvider)
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func openBillingPortal() {
        Task { await userStore.openBillingPortal() }
    }
}
