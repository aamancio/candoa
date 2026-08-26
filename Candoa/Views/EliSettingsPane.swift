import AppKit
import SwiftUI

internal struct EliSettingsPane: View {
    @State private var connection = EliPreferences.connection
    @State private var hostedModelID = EliPreferences.hostedModelID ?? ""
    @State private var directModelID = EliPreferences.directModel.id
    @State private var reasoningEffort = EliPreferences.reasoningEffort
    @State private var apiKey = ""
    @State private var savedKeyProviders = Set(
        AIProvider.allCases.filter(EliKeychain.hasAPIKey(for:))
    )
    @State private var keychainError: String?
    /// Per-provider model lists fetched from the provider's own API with the
    /// available credential; absent entries fall back to the curated catalog.
    @State private var dynamicDirectModels: [AIProvider: [AIModel]] = [:]
    // UI-test launches share the real defaults domain, so the pane starts
    // from an empty profile there: tests stay deterministic and the person's
    // own details never appear in a test's screenshots.
    @State private var profile = EliSettingsPane.isUITesting ? UserProfile() : UserProfileStore.load()
    /// The profile rows on screen: fields that held a value when the pane
    /// appeared, plus any the user added by hand this visit. Learned details
    /// simply show up filled; everything else stays out of sight — the pane
    /// reads as what Eli knows, not as a form to complete.
    @State private var visibleProfileFields: [UserProfile.Field] = []
    @EnvironmentObject private var userStore: UserStore

    /// UI-test launches share the real defaults domain, so persistence is
    /// suspended there; selections live in view state and launch-argument
    /// overrides only.
    private static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"
    }

    private var directModel: AIModel {
        AIModelCatalog.model(forID: directModelID)
            ?? listedDynamicModel(forID: directModelID)
            ?? persistedDynamicModel(forID: directModelID)
            ?? AIModelCatalog.directModels[0]
    }

    private func listedDynamicModel(forID id: String) -> AIModel? {
        dynamicDirectModels.values.joined().first { $0.id == id }
    }

    /// The metadata snapshot saved with a dynamic selection, so the pane
    /// resolves it before the provider list has loaded (or offline).
    private func persistedDynamicModel(forID id: String) -> AIModel? {
        let persisted = EliPreferences.directModel
        return persisted.id == id ? persisted : nil
    }

    private var selectedProvider: AIProvider { directModel.provider }

    private var connectionOptions: [SettingsPickerOption] {
        var connections: [EliConnection] = [.candoaCloud, .personalKey]
#if DEBUG
        if AIProvider.allCases.contains(where: {
            EliPreferences.environmentAPIKey(for: $0) != nil
        }) || connection == .environment {
            connections.append(.environment)
        }
#endif
        return connections.map { SettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
    }

    private var providerOptions: [SettingsPickerOption] {
        let providers: [AIProvider]
        if connection == .environment {
            let available = AIProvider.allCases.filter {
                EliPreferences.environmentAPIKey(for: $0) != nil
            }
            providers = available.isEmpty ? AIProvider.allCases : available
        } else {
            providers = AIProvider.allCases
        }
        return providers.map { SettingsPickerOption(id: $0.rawValue, title: $0.displayName) }
    }

    private var directModelOptions: [SettingsPickerOption] {
        let models = dynamicDirectModels[selectedProvider]
            ?? AIModelCatalog.directModels(for: selectedProvider)
        var options = models.map {
            SettingsPickerOption(id: $0.id, title: $0.displayName)
        }
        if !options.contains(where: { $0.id == directModelID }),
           directModel.id == directModelID {
            options.insert(
                SettingsPickerOption(id: directModel.id, title: directModel.displayName),
                at: 0
            )
        }
        return options
    }

    private var hostedModelOptions: [SettingsPickerOption] {
        [SettingsPickerOption(id: "", title: String(localized: "Automatic"))]
            + userStore.hostedModels.map {
                SettingsPickerOption(id: $0.id, title: Self.hostedOptionTitle(for: $0))
            }
    }

    /// Hosted options carry their server-priced credit cost so the tradeoff
    /// is visible at the moment of choosing, not after the bill. The price is
    /// per message: a browser task runs several steps and settles at a higher
    /// weight, which the picker's subtitle says plainly rather than guessing a
    /// number the server owns.
    private static func hostedOptionTitle(for model: AIModel) -> String {
        guard let cost = model.creditCost else { return model.displayName }
        let price = cost == 1
            ? String(localized: "1 credit per message")
            : String(localized: "\(cost) credits per message")
        return "\(model.displayName) (\(price))"
    }

    private var reasoningOptions: [SettingsPickerOption] {
        let efforts = connection == .candoaCloud
            ? AIReasoningEffort.allCases
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
                        title: String(localized: "Connection"),
                        subtitle: connection == .candoaCloud
                            ? String(localized: "Use your Candoa subscription with server-managed credentials.")
                            : String(localized: "Send requests directly from this Mac to the selected provider."),
                        selection: connectionBinding,
                        options: connectionOptions
                    )

                    SettingsDivider()

                    if connection == .candoaCloud {
                        SettingsPickerRow(
                            systemImage: "cpu",
                            title: String(localized: "Model"),
                            subtitle: userStore.hostedModels.isEmpty
                                ? String(localized: "Automatic uses your plan's default model. Sign in to choose from your plan's models.")
                                : String(localized: "Models available on your Candoa plan. A browser task costs more than a message, because Eli works through several steps."),
                            selection: hostedModelBinding,
                            options: hostedModelOptions
                        )
                    } else {
                        SettingsPickerRow(
                            systemImage: "building.2",
                            title: String(localized: "Provider"),
                            subtitle: String(localized: "Direct requests use this provider's API with your own credentials."),
                            selection: providerBinding,
                            options: providerOptions
                        )

                        SettingsDivider()

                        SettingsPickerRow(
                            systemImage: "cpu",
                            title: String(localized: "Model"),
                            subtitle: dynamicDirectModels[selectedProvider] != nil
                                ? String(localized: "Current \(selectedProvider.displayName) models available to your key.")
                                : String(localized: "Curated current models for \(selectedProvider.displayName)."),
                            selection: directModelBinding,
                            options: directModelOptions
                        )
                    }

                    SettingsDivider()

                    SettingsPickerRow(
                        systemImage: "brain",
                        title: String(localized: "Reasoning"),
                        subtitle: String(localized: "How much the model thinks before answering. Low is fastest."),
                        selection: reasoningBinding,
                        options: reasoningOptions
                    )
                }

                profileSection

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
        .task(id: dynamicModelFetchKey) {
            await refreshDynamicDirectModels()
        }
    }

    /// What Eli may type into a form. Values arrive two ways — learned from
    /// Ask conversations the way memory is, or typed here — and typing a
    /// field claims it for the user: extraction never overwrites a hand-typed
    /// value. A blank field stays blank on the page rather than guessed at.
    private var profileSection: some View {
        Group {
            SettingsSectionTitle("Your Details")

            SettingsCard {
                Text("Eli learns these from your conversations and fills them into forms you ask it to complete. You can correct or clear anything here, and blank fields stay blank on the page. Passwords, payment details, and government IDs are never stored.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                    .padding(.bottom, 4)

                if visibleProfileFields.isEmpty {
                    Text("Eli hasn't learned any details yet — things you share in conversations show up here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                } else {
                    ForEach(visibleProfileFields, id: \.self) { field in
                        SettingsTextFieldRow(title: profileFieldTitle(field), text: profileFieldBinding(field))
                    }
                }

                if !hiddenProfileFields.isEmpty {
                    HStack {
                        Menu(String(localized: "Add Detail")) {
                            ForEach(hiddenProfileFields, id: \.self) { field in
                                Button(profileFieldTitle(field)) {
                                    visibleProfileFields.append(field)
                                }
                            }
                        }
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
                }
            }
            .accessibilityIdentifier("eli-profile-card")
        }
        .onAppear {
            visibleProfileFields = UserProfile.Field.allCases.filter { field in
                !profile[field].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        .onChange(of: profile) { previous, updated in
            // UI-test launches share the real defaults domain, so the pane
            // never writes a test's typing into the person's own profile.
            guard !Self.isUITesting else { return }
            // An edited field becomes the user's: extraction stops updating it.
            let edited = UserProfile.Field.allCases.filter { previous[$0] != updated[$0] }
            if !edited.isEmpty {
                UserProfileStore.saveLearnedFields(
                    UserProfileStore.loadLearnedFields().subtracting(edited)
                )
            }
            UserProfileStore.save(updated)
        }
    }

    /// Fields with nothing to show and not yet added by hand — the Add
    /// Detail menu's contents.
    private var hiddenProfileFields: [UserProfile.Field] {
        UserProfile.Field.allCases.filter { !visibleProfileFields.contains($0) }
    }

    private func profileFieldBinding(_ field: UserProfile.Field) -> Binding<String> {
        Binding(
            get: { profile[field] },
            set: { profile[field] = $0 }
        )
    }

    private func profileFieldTitle(_ field: UserProfile.Field) -> String {
        switch field {
        case .givenName: String(localized: "Given name")
        case .familyName: String(localized: "Family name")
        case .email: String(localized: "Email")
        case .phone: String(localized: "Phone")
        case .streetAddress: String(localized: "Street address")
        case .city: String(localized: "City")
        case .region: String(localized: "State or province")
        case .postalCode: String(localized: "Postal code")
        case .country: String(localized: "Country")
        case .organization: String(localized: "Organization")
        case .website: String(localized: "Website")
        }
    }

    private var personalKeySection: some View {
        Group {
            SettingsSectionTitle("Personal API Key")

            SettingsCard {
                SettingsRow(
                    systemImage: "lock",
                    title: savedKeyProviders.contains(selectedProvider)
                        ? String(localized: "Replace your \(selectedProvider.displayName) key")
                        : String(localized: "Save a \(selectedProvider.displayName) API key"),
                    subtitle: String(localized: "Candoa stores one key per provider in this Mac's Keychain. Keys are never sent to Candoa.")
                ) {
                    HStack(spacing: 8) {
                        SecureField(selectedProvider.keyPlaceholder, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 170)

                        Button(
                            savedKeyProviders.contains(selectedProvider) ? "Replace" : "Save",
                            action: saveAPIKey
                        )
                        .buttonTreatment(.secondary)
                        .controlSize(.small)
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                if savedKeyProviders.contains(selectedProvider) {
                    SettingsDivider()

                    SettingsRow(
                        systemImage: "checkmark.shield",
                        title: String(localized: "\(selectedProvider.displayName) key saved"),
                        subtitle: String(localized: "Eli sends direct requests with this key while \(selectedProvider.displayName) is selected.")
                    ) {
                        Button("Remove", role: .destructive, action: removeAPIKey)
                            .buttonTreatment(.secondary)
                            .controlSize(.small)
                    }
                } else {
                    SettingsDivider()

                    SettingsRow(
                        systemImage: "exclamationmark.triangle",
                        title: String(localized: "No \(selectedProvider.displayName) key on this Mac"),
                        subtitle: String(localized: "Eli can't use the direct \(selectedProvider.displayName) connection until you save a key.")
                    ) {
                        EmptyView()
                    }
                }

                if let keychainError {
                    SettingsDivider()

                    Text(keychainError)
                        .font(.callout)
                        .foregroundStyle(AppColor.danger)
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
                    systemImage: EliPreferences.environmentAPIKey(for: selectedProvider) != nil
                        ? "checkmark.shield"
                        : "exclamationmark.triangle",
                    title: EliPreferences.environmentAPIKey(for: selectedProvider) != nil
                        ? String(localized: "\(selectedProvider.environmentVariable) is set")
                        : String(localized: "\(selectedProvider.environmentVariable) is not set"),
                    subtitle: String(localized: "Debug builds only: reads the provider key from this process's environment.")
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
                        : String(localized: "No active Candoa subscription"),
                    subtitle: userStore.hasActiveSubscription
                        ? String(localized: "Manage payment details, invoices, or your plan in Stripe.")
                        : String(localized: "Open Eli to subscribe to Candoa Pro.")
                ) {
                    if userStore.hasActiveSubscription {
                        Button("Manage", action: openBillingPortal)
                            .buttonTreatment(.secondary)
                            .controlSize(.small)
                            .disabled(userStore.isWorking)
                    }
                }

                if let credits = userStore.status?.credits {
                    SettingsDivider()
                    creditsUsageRow(credits)
                }

                if let subscription = userStore.status?.subscription {
                    SettingsDivider()
                    billingRow(subscription)
                }

                if userStore.hasCloudSession, userStore.status != nil {
                    SettingsDivider()

                    SettingsRow(
                        systemImage: "arrow.clockwise",
                        title: String(localized: "Refresh subscription details"),
                        subtitle: lastUpdatedDescription
                    ) {
                        Button("Refresh") {
                            Task {
                                await userStore.refresh()
                            }
                        }
                        .buttonTreatment(.secondary)
                        .controlSize(.small)
                        .disabled(userStore.isWorking)
                        .accessibilityIdentifier("subscription-refresh-button")
                    }
                }

                SettingsDivider()

                SettingsRow(
                    systemImage: userStore.status?.hasAppleAccount == true
                        ? "checkmark.circle.fill"
                        : "apple.logo",
                    title: userStore.status?.hasAppleAccount == true
                        ? String(localized: "Signed in with Apple")
                        : String(localized: "Restore your Candoa account"),
                    subtitle: userStore.status?.hasAppleAccount == true
                        ? String(localized: "Subscriptions and hosted services follow your Apple-linked Candoa account.")
                        : String(localized: "Sign in with Apple to use your subscription on this or another Mac.")
                ) {
                    if userStore.status?.hasAppleAccount != true {
                        Button(
                            userStore.isSigningInWithApple
                                ? String(localized: "Signing In…")
                                : String(localized: "Sign In with Apple")
                        ) {
                            userStore.signInWithApple()
                        }
                        .buttonTreatment(.secondary)
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

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(accountError)
                            .font(.callout)
                            .foregroundStyle(AppColor.danger)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if userStore.hasCloudSession {
                            Button("Try Again") {
                                Task {
                                    await userStore.refresh()
                                }
                            }
                            .buttonTreatment(.secondary)
                            .controlSize(.small)
                            .disabled(userStore.isWorking)
                            .accessibilityIdentifier("account-refresh-retry-button")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    /// Usage is presented in provider-neutral Candoa credits with the numbers
    /// spelled out in text, so the progress bar is reinforcement rather than
    /// the only signal.
    private func creditsUsageRow(_ credits: AccountCredits) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: credits.isExhausted ? "gauge.with.needle.fill" : "gauge.with.needle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "\(credits.usedCredits.formatted()) of "
                    + "\(credits.monthlyAllowance.formatted()) Candoa credits used"
                )
                .font(.system(size: 13))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("subscription-usage-summary")

                ProgressView(
                    value: Double(min(credits.usedCredits, credits.monthlyAllowance)),
                    total: Double(max(credits.monthlyAllowance, 1))
                )
                .progressViewStyle(.linear)
                .frame(maxWidth: 240)
                .accessibilityHidden(true)

                Text(creditsSubtitle(credits))
                    .font(.system(size: 11.5))
                    .foregroundStyle(credits.isExhausted ? AnyShapeStyle(AppColor.danger) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("subscription-usage-detail")
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func creditsSubtitle(_ credits: AccountCredits) -> String {
        let reset = credits.periodEnd.map {
            String(localized: "They reset on \($0.formatted(date: .abbreviated, time: .omitted)).")
        } ?? String(localized: "The reset date isn’t available yet.")
        let explanation = String(localized: "Usage is measured in provider-neutral Candoa credits, not raw tokens.")
        return credits.isExhausted
            ? String(localized: "You’ve used all of this period’s credits. \(reset) \(explanation)")
            : String(localized: "\(reset) \(explanation)")
    }

    private func billingRow(_ subscription: AccountSubscription) -> some View {
        let details = billingDetails(subscription)
        return SettingsRow(
            systemImage: details.systemImage,
            title: details.title,
            subtitle: details.subtitle
        ) {
            EmptyView()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subscription-billing-row")
    }

    private func billingDetails(
        _ subscription: AccountSubscription
    ) -> (systemImage: String, title: String, subtitle: String) {
        let periodEnd = subscription.currentPeriodEnd
            .map { $0.formatted(date: .abbreviated, time: .omitted) }

        switch subscription.status {
        case "trialing":
            return (
                "clock",
                periodEnd.map { String(localized: "Trial ends \($0)") } ?? String(localized: "Trial in progress"),
                String(localized: "Your paid subscription starts when the trial ends. The exact charge appears in the billing portal.")
            )
        case "active" where subscription.cancelAtPeriodEnd:
            return (
                "calendar.badge.minus",
                periodEnd.map { String(localized: "Subscription ends \($0)") } ?? String(localized: "Subscription is scheduled to end"),
                String(localized: "Your plan stays active until then, and credits won’t renew afterward. Use Manage to resume it.")
            )
        case "active":
            return (
                "calendar",
                periodEnd.map { String(localized: "Next billing date: \($0)") } ?? String(localized: "Next billing date isn’t available yet"),
                String(localized: "The exact charge amount appears in the billing portal via Manage.")
            )
        case "past_due", "unpaid":
            return (
                "exclamationmark.triangle",
                String(localized: "Payment is past due"),
                String(localized: "Update your payment method in the billing portal to keep your plan and credits.")
            )
        case "canceled", "incomplete_expired":
            return (
                "calendar.badge.minus",
                periodEnd.map { String(localized: "Subscription ended \($0)") } ?? String(localized: "Subscription ended"),
                String(localized: "Open Eli to subscribe again and restore hosted models.")
            )
        default:
            return (
                "calendar",
                String(localized: "Subscription status: \(subscription.status.replacingOccurrences(of: "_", with: " "))"),
                String(localized: "Check the billing portal via Manage for details.")
            )
        }
    }

    private var lastUpdatedDescription: String {
        guard let updated = userStore.statusLastUpdated else {
            return String(localized: "Waiting for the first update from Candoa Cloud.")
        }
        let relative = updated.formatted(.relative(presentation: .named))
        return String(localized: "Updated \(relative).")
    }

    private var connectionBinding: Binding<String> {
        Binding(
            get: { connection.rawValue },
            set: { newValue in
                guard let newConnection = EliConnection(rawValue: newValue) else { return }
                connection = newConnection
                if !Self.isUITesting {
                    EliPreferences.setConnection(newConnection)
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
                persist(newValue, forKey: SettingsOption.askHostedModel)
            }
        )
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { selectedProvider.rawValue },
            set: { newValue in
                guard let provider = AIProvider(rawValue: newValue),
                      provider != selectedProvider else { return }
                setDirectModel(AIModelCatalog.directDefaultModel(for: provider).id)
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
                guard let effort = AIReasoningEffort(rawValue: newValue) else { return }
                reasoningEffort = effort
                persist(effort.rawValue, forKey: SettingsOption.askReasoningEffort)
            }
        )
    }

    private func setDirectModel(_ modelID: String) {
        guard let model = AIModelCatalog.model(forID: modelID)
            ?? listedDynamicModel(forID: modelID) else { return }
        directModelID = modelID
        if !Self.isUITesting {
            EliPreferences.setDirectModel(model)
        }
        apiKey = ""
        keychainError = nil
        coerceReasoningEffort()
    }

    /// Refetch whenever the route, provider, or key availability changes.
    private var dynamicModelFetchKey: String {
        "\(connection.rawValue)|\(selectedProvider.rawValue)|"
            + "\(savedKeyProviders.contains(selectedProvider))"
    }

    private func refreshDynamicDirectModels() async {
        guard connection != .candoaCloud,
              dynamicDirectModels[selectedProvider] == nil,
              let credential = dynamicListingCredential else { return }
        let provider = selectedProvider
        guard let models = try? await ProviderModelDirectory.models(
            for: provider,
            apiKey: credential
        ), !models.isEmpty else { return }
        dynamicDirectModels[provider] = models
        coerceReasoningEffort()
    }

    /// The key used to list models for the selected provider, mirroring the
    /// request routes: saved personal key, or the Debug environment key. UI
    /// tests inject a fixture list instead of reaching provider APIs, so a
    /// placeholder unlocks the fetch there.
    private var dynamicListingCredential: String? {
#if DEBUG
        if Self.isUITesting {
            return ProcessInfo.processInfo
                .environment["CANDOA_UI_TESTING_DIRECT_MODELS"] != nil
                ? "ui-testing-fixture"
                : nil
        }
#endif
        switch connection {
        case .candoaCloud:
            return nil
        case .personalKey:
            return EliKeychain.apiKey(for: selectedProvider)
        case .environment:
            return EliPreferences.environmentAPIKey(for: selectedProvider)
        }
    }

    /// Coerces stale stored IDs back into the catalog and persists the
    /// resolved selection, mirroring normalizeDefaultSearchProvider().
    private func normalizeSelections() {
        if !Self.isUITesting {
            EliPreferences.setConnection(connection)
            persist(directModelID, forKey: SettingsOption.askDirectModel)
            persist(reasoningEffort.rawValue, forKey: SettingsOption.askReasoningEffort)
        }
        coerceReasoningEffort()
    }

    private func coerceReasoningEffort() {
        guard connection != .candoaCloud else { return }
        let clamped = directModel.clampedEffort(reasoningEffort)
        if clamped != reasoningEffort {
            reasoningEffort = clamped
            persist(clamped.rawValue, forKey: SettingsOption.askReasoningEffort)
        }
    }

    private func persist(_ value: String, forKey key: String) {
        guard !Self.isUITesting else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    private func saveAPIKey() {
        do {
            try EliKeychain.save(apiKey, for: selectedProvider)
            apiKey = ""
            savedKeyProviders.insert(selectedProvider)
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    private func removeAPIKey() {
        do {
            try EliKeychain.remove(for: selectedProvider)
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
