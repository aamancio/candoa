import AppKit
import AuthenticationServices
import os
import SwiftUI
import UniformTypeIdentifiers

struct EliSidebarView: View {
    private static let eliLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Candoa",
        category: "Eli"
    )

    @ObservedObject var store: BrowserStore
    @Binding var uiTestingState: String
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var userStore: UserStore
    @StateObject private var speechController = AISidebarSpeechController()
    @State private var prompt = ""
    @State private var messages: [AISidebarMessage] = []
    @State private var mentionedContext: [AISidebarContextMention] = []
    @State private var isMentionMenuPresented = false
    @State private var isFileImporterPresented = false
    @State private var selectedMentionIndex = 0
    @State private var streamTask: Task<Void, Never>?
    @State private var includesCurrentPageContext = true
    @State private var lastSubmittedPageContext: CandoaAIPageContext?
    @State private var pendingPageAction: CandoaPageActionProposal?
    @State private var pendingActionTabID: UUID?
    @FocusState private var isPromptFocused: Bool

    private var activePageTitle: String {
        let title = store.activeTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Current Page" : title
    }

    private var activePageSubtitle: String {
        store.activeTab?.url?.host(percentEncoded: false) ?? ""
    }

    private var mentionQuery: String? {
        let text = prompt as NSString
        let selectedRange = NSApp.keyWindow?.firstResponder
            .flatMap { $0 as? NSTextView }?
            .selectedRange() ?? NSRange(location: text.length, length: 0)
        let cursorLocation = min(selectedRange.location, text.length)
        let prefix = text.substring(to: cursorLocation)
        guard let atRange = prefix.range(of: "@", options: .backwards) else { return nil }
        let token = String(prefix[atRange.upperBound...])
        guard token.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return token
    }

    private var availableTabMentions: [BrowserTab] {
        let query = trimmedMentionQuery
        let tabs = store.visibleTabsForActiveSpace
        guard !query.isEmpty else { return tabs }
        return tabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(query) ||
                (tab.url?.host(percentEncoded: false)?.localizedCaseInsensitiveContains(query) ?? false) ||
                (tab.url?.absoluteString.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var trimmedMentionQuery: String {
        mentionQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var tabMentionOptions: [AISidebarMentionOption] {
        let tabOptions = availableTabMentions.prefix(6).map { tab in
            AISidebarMentionOption(
                id: "tab-\(tab.id.uuidString)",
                title: tab.title,
                detail: tab.url?.host(percentEncoded: false),
                symbolName: tab.faviconSymbol,
                faviconData: tab.faviconData,
                action: .mention(.tab(tab.id))
            )
        }

        return tabOptions + historyMentionOptions
    }

    private var historyMentionOptions: [AISidebarMentionOption] {
        guard !trimmedMentionQuery.isEmpty else { return [] }

        let openTabURLKeys = Set(store.visibleTabsForActiveSpace.compactMap {
            $0.url.map { normalizedMentionURLKey($0) }
        })

        return store.recentHistory(matching: trimmedMentionQuery, limit: 6)
            .filter { !openTabURLKeys.contains(normalizedMentionURLKey($0.url)) }
            .map { visit in
                let title = visit.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = visit.url.host(percentEncoded: false) ?? visit.url.absoluteString
                return AISidebarMentionOption(
                    id: "history-\(visit.id.uuidString)",
                    title: title.isEmpty ? host : title,
                    detail: "\(host) - History",
                    symbolName: FaviconService.shared.placeholderSymbol(for: visit.url),
                    faviconData: nil,
                    action: .mention(
                        .history(
                            AISidebarHistoryContext(
                                id: visit.id,
                                title: title.isEmpty ? host : title,
                                url: visit.url
                            )
                        )
                    )
                )
            }
    }

    private var fileMentionOptions: [AISidebarMentionOption] {
        guard trimmedMentionQuery.isEmpty else { return [] }
        return [
            AISidebarMentionOption(
                id: "upload-file",
                title: "Upload file from computer",
                detail: "Text files",
                symbolName: "doc.badge.plus",
                faviconData: nil,
                action: .uploadFile
            )
        ]
    }

    private var mentionOptions: [AISidebarMentionOption] {
        tabMentionOptions + fileMentionOptions
    }

    private var contextChips: [AISidebarContextChip] {
        let currentChip = includesCurrentPageContext ? [
            AISidebarContextChip(
                id: "current",
                title: activePageTitle,
                subtitle: activePageSubtitle,
                symbolName: store.activeTab?.faviconSymbol ?? "safari",
                faviconData: store.activeTab?.faviconData,
                isRemovable: true
            )
        ] : []

        return currentChip + mentionedContext.map { chip(for: $0) }
    }

    private var panelBackgroundColor: Color {
        guard let appearance = NSAppearance(
            named: colorScheme == .dark ? .darkAqua : .aqua
        ) else {
            return CandoaChromeStyle.windowBackground
        }

        var resolvedColor = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
                ?? NSColor.windowBackgroundColor
        }
        return Color(nsColor: resolvedColor)
    }

    private var hasPersonalEliAccess: Bool {
        CandoaEliPreferences.usesPersonalOpenAIKey && CandoaEliKeychain.hasAPIKey
    }

    private var hasEliAccess: Bool {
        hasPersonalEliAccess || userStore.hasActiveSubscription
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if !hasEliAccess {
                Spacer(minLength: 60)
                subscriptionGate
                Spacer(minLength: 60)
            } else if messages.isEmpty {
                Spacer(minLength: 60)
                emptyState
                Spacer(minLength: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(messages) { message in
                                AISidebarMessageRow(
                                    message: message,
                                    themeColorHex: store.activeThemeColorHexes.first
                                )
                                    .id(message.id)
                            }
                        }
                        .padding(14)
                    }
                    .onChange(of: messages) { _, updatedMessages in
                        guard let lastID = updatedMessages.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }

            if hasEliAccess {
                composer
            }
        }
        .background(panelBackgroundColor)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(CandoaChromeStyle.sidebarBorder)
                .frame(width: 1)
        }
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            uiTestingState = uiTestingAgentState
            DispatchQueue.main.async {
                isPromptFocused = true
            }
        }
        .task {
            await userStore.refresh()
        }
        .onDisappear {
            uiTestingState = ""
            cancelStream()
            speechController.cancelListening()
        }
        .onChange(of: uiTestingAgentState) { _, state in
            uiTestingState = state
        }
        .onChange(of: store.activeTabID) {
            includesCurrentPageContext = true
        }
        .onChange(of: store.activeTab?.url) {
            includesCurrentPageContext = true
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.text, .plainText, .json, .sourceCode, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
        .confirmationDialog(
            pendingPageAction?.confirmationTitle ?? "Allow Eli to act?",
            isPresented: Binding(
                get: { pendingPageAction != nil },
                set: { if !$0 { pendingPageAction = nil; pendingActionTabID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Allow Once") { approvePendingPageAction() }
            Button("Cancel", role: .cancel) { pendingPageAction = nil; pendingActionTabID = nil }
        } message: {
            Text(pendingPageAction?.confirmationDetail ?? "")
        }
        .accessibilityIdentifier("agent-sidebar")
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            AISidebarTopBarIconButton(
                symbolName: "square.and.pencil",
                helpText: "New Eli Conversation"
            ) {
                prompt = ""
                mentionedContext = []
                messages = []
                includesCurrentPageContext = true
                lastSubmittedPageContext = nil
                cancelStream()
            }

            Spacer()

            AISidebarTopBarIconButton(
                symbolName: "xmark",
                helpText: "Close Eli Sidebar",
                iconSize: 18
            ) {
                onClose()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("What can Eli do?")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                .padding(.horizontal, 2)

            ForEach(starterHints) { hint in
                AISidebarStarterHintButton(
                    hint: hint,
                    accentColor: eliAccentColor
                ) {
                    submitPrompt(hint.prompt)
                }
            }
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var subscriptionGate: some View {
        EliSubscriptionGateView(accentColor: eliAccentColor, userStore: userStore)
    }

    private var starterHints: [AISidebarStarterHint] {
        [
            AISidebarStarterHint(
                title: "Summarize this page",
                prompt: "Summarize this page.",
                symbolName: "doc.text"
            ),
            AISidebarStarterHint(
                title: "What are the key details?",
                prompt: "What are the key details on this page?",
                symbolName: "list.bullet"
            ),
            AISidebarStarterHint(
                title: "What should I do next?",
                prompt: "Based on this page, what should I do next?",
                symbolName: "arrow.turn.down.right"
            )
        ]
    }

    private var eliAccentColor: Color {
        guard let hex = store.activeThemeColorHexes.first else {
            return CandoaColor.primary
        }
        return Color(spaceHex: hex)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if isMentionMenuPresented {
                mentionMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            inputSurface
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var inputSurface: some View {
        let hasContext = !contextChips.isEmpty

        return VStack(alignment: .leading, spacing: hasContext ? 12 : 0) {
            if hasContext {
                contextTagRow
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Tell Eli what to do...", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 14))
                    .focused($isPromptFocused)
                    .accessibilityIdentifier("agent-input-field")
                    .onSubmit {
                        if !performSelectedMention() {
                            submitPrompt()
                        }
                    }
                    .onChange(of: prompt) { _, _ in
                        syncMentionMenu()
                    }
                    .onKeyPress(.return) {
                        if performSelectedMention() {
                            return .handled
                        }

                        submitPrompt()
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard isMentionMenuPresented else { return .ignored }
                        moveMentionSelection(by: 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard isMentionMenuPresented else { return .ignored }
                        moveMentionSelection(by: -1)
                        return .handled
                    }

                AISidebarComposerIconButton(symbolName: "plus", helpText: "Add Context") {
                    showMentionMenuFromButton()
                }

                AISidebarComposerIconButton(
                    symbolName: "mic",
                    helpText: speechController.isListening ? "Stop Listening" : "Dictate"
                ) {
                    handleMicButton()
                }

                AISidebarComposerSendButton(
                    isEnabled: !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    submitPrompt()
                }
                .accessibilityIdentifier("agent-send-button")
            }

            if speechController.isListening || speechController.statusMessage != nil {
                speechStatusRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, hasContext ? 12 : 9)
        .padding(.bottom, hasContext ? 10 : 9)
        .background {
            RoundedRectangle(cornerRadius: hasContext ? 16 : 14, style: .continuous)
                .fill(CandoaChromeStyle.sidebarControlFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: hasContext ? 16 : 14, style: .continuous)
                .stroke(CandoaChromeStyle.sidebarControlStroke, lineWidth: 1)
        }
    }

    private var speechStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(speechController.displayText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                .lineLimit(1)
                .padding(.leading, 4)

            HStack(spacing: 9) {
                Button {
                    speechController.cancelListening()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CandoaChromeStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(!speechController.isListening)
                .help("Cancel Dictation")

                AISidebarSpeechWaveformView()
                    .frame(height: 18)

                Text(speechController.elapsedText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CandoaChromeStyle.sidebarIcon)
                    .frame(width: 38, alignment: .trailing)

                Button {
                    commitSpeechTranscript()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(speechController.isListening ? CandoaChromeStyle.sidebarTextSecondary : CandoaChromeStyle.sidebarIcon)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .disabled(!speechController.isListening)
                .help("Stop Dictation")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
    }

    private var contextTagRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(contextChips) { chip in
                    AISidebarContextChipView(chip: chip) {
                        removeMention(chip.id)
                    }
                }
            }
            .padding(.top, 10)
            .padding(.trailing, 10)
        }
    }

    private var mentionMenu: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("TABS")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                .padding(.horizontal, 10)

            ForEach(Array(tabMentionOptions.enumerated()), id: \.element.id) { index, option in
                mentionButton(
                    option: option,
                    isSelected: index == selectedMentionIndex
                )
            }

            if !fileMentionOptions.isEmpty {
                Divider()

                Text("FILES")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                    .padding(.horizontal, 10)

                ForEach(Array(fileMentionOptions.enumerated()), id: \.element.id) { index, option in
                    mentionButton(
                        option: option,
                        isSelected: tabMentionOptions.count + index == selectedMentionIndex
                    )
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CandoaChromeStyle.popoverBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandoaChromeStyle.popoverBorder, lineWidth: 1)
        }
        .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 16, y: 8)
    }

    private func mentionButton(
        option: AISidebarMentionOption,
        isSelected: Bool
    ) -> some View {
        AISidebarMentionButton(
            title: option.title,
            detail: option.detail,
            symbolName: option.symbolName,
            faviconData: option.faviconData,
            isSelected: isSelected,
            action: {
                runMentionOption(option)
            }
        )
    }

    private var uiTestingAgentState: String {
        let composerChipText = contextChips
            .map { "\($0.title)|\($0.subtitle)" }
            .joined(separator: ",")
        let lastUserText = messages.last { $0.role == .user }?.text ?? ""
        let lastAssistantText = messages.last { $0.role == .assistant }?.text ?? ""
        let messageText = messages.enumerated()
            .map { index, message in
                let role = message.role == .user ? "user" : "assistant"
                let sentChipText = message.contextChips
                    .map { "\($0.title)|\($0.subtitle)" }
                    .joined(separator: ",")
                return "\(index):\(role):chips=[\(sentChipText)]:text=\(message.text)"
            }
            .joined(separator: "||")

        return "composerChips=[\(composerChipText)];lastUser=[\(lastUserText)];lastAssistant=[\(lastAssistantText)];messages=[\(messageText)]"
    }

    private func submitPrompt(_ promptOverride: String? = nil) {
        let submittedPrompt = (promptOverride ?? prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard CandoaEliPromptPolicy.canSubmit(submittedPrompt, hasConversation: !messages.isEmpty) else { return }

        if let action = CandoaPageActionProposal.parse(submittedPrompt) {
            prompt = ""
            messages.append(AISidebarMessage(role: .user, text: submittedPrompt, isStreaming: false))
            messages.append(AISidebarMessage(role: .assistant, text: "I can \(action.confirmationTitle.lowercased()). Please confirm first.", isStreaming: false))
            pendingActionTabID = store.activeTabID
            pendingPageAction = action
            return
        }

        prompt = ""
        cancelStream()

        let submittedContextChips = contextChips.map {
            AISidebarContextChip(
                id: $0.id,
                title: $0.title,
                subtitle: $0.subtitle,
                symbolName: $0.symbolName,
                faviconData: $0.faviconData,
                isRemovable: false
            )
        }
        let contextMentions = mentionedContext
        let normalizedSubmittedPrompt = CandoaEliPromptPolicy.normalizedText(submittedPrompt)
        let existingRecentTurns = recentTurns()
        let shouldRefreshCurrentPageContext = CandoaEliDrafts.asksAboutVisibleControl(
            normalizedSubmittedPrompt,
            recentTurns: existingRecentTurns
        )
        let includesCurrentPage = includesCurrentPageContext || shouldRefreshCurrentPageContext
        let currentPageTabID = includesCurrentPage ? store.activeTabID : nil
        let inheritedPageContext = lastSubmittedPageContext
        let shouldUseCurrentContextOnly = !submittedContextChips.isEmpty
            && CandoaEliDrafts.referencesCurrentPage(normalizedSubmittedPrompt)
        let recentTurns = shouldUseCurrentContextOnly ? [] : existingRecentTurns

        messages.append(AISidebarMessage(
            role: .user,
            text: submittedPrompt,
            isStreaming: false,
            contextChips: submittedContextChips
        ))

        let responseID = UUID()
        messages.append(AISidebarMessage(id: responseID, role: .assistant, text: "", isStreaming: true))

        mentionedContext = []
        includesCurrentPageContext = false
        isMentionMenuPresented = false

        streamTask = Task {
            let submittedPageContext = await combinedContext(
                for: contextMentions,
                currentPageTabID: currentPageTabID
            )
            let pageContext = submittedPageContext.hasAttachedContext
                ? submittedPageContext
                : inheritedPageContext ?? submittedPageContext

            if submittedPageContext.hasAttachedContext {
                await MainActor.run {
                    lastSubmittedPageContext = submittedPageContext
                }
            }

            let remoteContext = CandoaEliContextCompactor.compactedContextIfNeeded(
                from: pageContext,
                prompt: submittedPrompt
            ) ?? pageContext
            await streamRemoteAIResponse(
                prompt: submittedPrompt,
                context: remoteContext,
                recentTurns: recentTurns,
                responseID: responseID
            )
        }
    }

    private func approvePendingPageAction() {
        guard let action = pendingPageAction else { return }
        let tabID = pendingActionTabID
        pendingPageAction = nil
        pendingActionTabID = nil
        Task {
            let result = await store.performAIPageAction(action, in: tabID)
            await MainActor.run {
                messages.append(AISidebarMessage(role: .assistant, text: result, isStreaming: false))
            }
        }
    }

    private func streamRemoteAIResponse(
        prompt: String,
        context: CandoaAIPageContext,
        recentTurns: [CandoaAIConversationTurn],
        responseID: UUID
    ) async {
        do {
            var response = ""
            var displayedCharacterCount = 0
            for try await fragment in CandoaRemoteEliService.streamResponse(
                to: prompt,
                context: context,
                recentTurns: recentTurns
            ) {
                guard !Task.isCancelled else { return }
                response += fragment
                guard response.count - displayedCharacterCount >= 24 else { continue }

                await MainActor.run {
                    guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                    messages[index].text = response
                }
                displayedCharacterCount = response.count
            }

            guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showAgentUnavailableMessage(into: responseID)
                return
            }

            await MainActor.run {
                guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
                messages[index].text = response
                messages[index].isStreaming = false
                streamTask = nil
            }
            return
        } catch is CancellationError {
            return
        } catch {
            Self.eliLogger.error("Eli remote service request failed: \(error.localizedDescription, privacy: .public)")
            showAgentUnavailableMessage(for: error, into: responseID)
        }
    }

    @MainActor
    private func showAgentUnavailableMessage(
        for error: Error? = nil,
        into responseID: UUID
    ) {
        let errorDescription = error?.localizedDescription.lowercased() ?? ""
        let message: String

        if errorDescription.contains("api key") {
            message = "Add an OpenAI API key in Settings before using your own key."
        } else if errorDescription.contains("authentication")
            || errorDescription.contains("session")
            || errorDescription.contains("current plan") {
            message = "Eli requires a signed-in Candoa account with an active Candoa subscription. Sign in or subscribe to continue."
        } else {
            message = "Eli is temporarily unavailable. Please try again later."
        }

        guard let index = messages.firstIndex(where: { $0.id == responseID }) else { return }
        messages[index].text = message
        messages[index].isStreaming = false
        streamTask = nil
    }

    private func combinedContext(
        for mentions: [AISidebarContextMention],
        currentPageTabID: UUID?
    ) async -> CandoaAIPageContext {
        let currentContext = currentPageTabID != nil
            ? await store.aiPageContext(for: currentPageTabID)
            : CandoaAIPageContext(title: nil, url: nil, text: nil)
        var sections: [String] = []

        if currentPageTabID != nil, !mentions.isEmpty {
            sections.append(contextSection(title: "Current page", context: currentContext))
        }

        for mention in mentions {
            switch mention {
            case .tab(let tabID):
                guard tabID != currentPageTabID else { continue }
                let tabContext = await store.aiPageContext(for: tabID)
                sections.append(contextSection(title: "Mentioned tab", context: tabContext))
            case .history(let historyContext):
                sections.append(
                    """
                    History page:
                    Title: \(historyContext.title)
                    URL: \(historyContext.url.absoluteString)
                    """
                )
            case .file(let fileContext):
                sections.append("Uploaded file: \(fileContext.name)\n\(fileContext.text)")
            }
        }

        let combinedText = sections
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return CandoaAIPageContext(
            title: currentContext.title,
            url: currentContext.url,
            text: combinedText.isEmpty ? currentContext.text : combinedText
        )
    }

    private func contextSection(title: String, context: CandoaAIPageContext) -> String {
        var lines = ["\(title):"]
        if let pageTitle = context.title, !pageTitle.isEmpty {
            lines.append("Title: \(pageTitle)")
        }
        if let url = context.url, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let text = context.text, !text.isEmpty {
            lines.append("Text excerpt:\n\(text)")
        }
        return lines.joined(separator: "\n")
    }

    private func syncMentionMenu() {
        isMentionMenuPresented = mentionQuery != nil
        selectedMentionIndex = 0
    }

    private func showMentionMenuFromButton() {
        if mentionQuery == nil {
            prompt += prompt.hasSuffix(" ") || prompt.isEmpty ? "@" : " @"
        }
        isMentionMenuPresented = true
        selectedMentionIndex = 0
        isPromptFocused = true
    }

    private func moveMentionSelection(by delta: Int) {
        let count = mentionOptions.count
        guard count > 0 else { return }
        selectedMentionIndex = ((selectedMentionIndex + delta) % count + count) % count
    }

    private func performSelectedMention() -> Bool {
        guard isMentionMenuPresented, mentionOptions.indices.contains(selectedMentionIndex) else {
            return false
        }

        runMentionOption(mentionOptions[selectedMentionIndex])
        return true
    }

    private func runMentionOption(_ option: AISidebarMentionOption) {
        switch option.action {
        case .mention(let mention):
            addMention(mention)
        case .uploadFile:
            clearMentionToken()
            isMentionMenuPresented = false
            isFileImporterPresented = true
        }
    }

    private func handleMicButton() {
        if speechController.isListening {
            commitSpeechTranscript()
            return
        }

        Task {
            await speechController.startListening()
        }
    }

    private func commitSpeechTranscript() {
        let transcript = speechController.stopListening()
        guard !transcript.isEmpty else { return }

        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = transcript
        } else {
            prompt += prompt.hasSuffix(" ") ? transcript : " \(transcript)"
        }
        isPromptFocused = true
    }

    private func addMention(_ mention: AISidebarContextMention) {
        guard !mentionedContext.contains(mention) else {
            clearMentionToken()
            isMentionMenuPresented = false
            return
        }

        mentionedContext.append(mention)
        clearMentionToken()
        isMentionMenuPresented = false
        isPromptFocused = true
    }

    private func removeMention(_ chipID: String) {
        if chipID == "current" {
            includesCurrentPageContext = false
            return
        }

        mentionedContext.removeAll { chip(for: $0).id == chipID }
    }

    private func chip(for mention: AISidebarContextMention) -> AISidebarContextChip {
        switch mention {
        case .tab(let id):
            let tab = store.tabs.first { $0.id == id }
            let tabTitle = tab?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return AISidebarContextChip(
                id: "tab-\(id.uuidString)",
                title: tabTitle?.isEmpty == false ? tabTitle! : "Mentioned tab",
                subtitle: tab?.url?.host(percentEncoded: false) ?? "",
                symbolName: tab?.faviconSymbol ?? "macwindow",
                faviconData: tab?.faviconData,
                isRemovable: true
            )
        case .history(let historyContext):
            return AISidebarContextChip(
                id: "history-\(historyContext.id.uuidString)",
                title: historyContext.title,
                subtitle: historyContext.url.host(percentEncoded: false) ?? "History",
                symbolName: FaviconService.shared.placeholderSymbol(for: historyContext.url),
                faviconData: nil,
                isRemovable: true
            )
        case .file(let fileContext):
            return AISidebarContextChip(
                id: "file-\(fileContext.id.uuidString)",
                title: fileContext.name,
                subtitle: "Uploaded file",
                symbolName: "doc.text",
                faviconData: nil,
                isRemovable: true
            )
        }
    }

    private func normalizedMentionURLKey(_ url: URL) -> String {
        var key = url.absoluteString.lowercased()
        if key.hasSuffix("/") {
            key.removeLast()
        }
        return key
    }

    private func clearMentionToken() {
        guard mentionQuery != nil else { return }
        let text = prompt as NSString
        let selectedRange = NSApp.keyWindow?.firstResponder
            .flatMap { $0 as? NSTextView }?
            .selectedRange() ?? NSRange(location: text.length, length: 0)
        let cursorLocation = min(selectedRange.location, text.length)
        let prefix = text.substring(to: cursorLocation)
        guard prefix.range(of: "@", options: .backwards) != nil else { return }

        let nsAtLocation = (prefix as NSString).range(of: "@", options: .backwards).location
        let replacementRange = NSRange(location: nsAtLocation, length: cursorLocation - nsAtLocation)
        prompt = text.replacingCharacters(in: replacementRange, with: "")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }

        let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if contentType?.conforms(to: .image) == true {
            guard
                let image = NSImage(contentsOf: url),
                let recognizedText = CandoaImageTextRecognizer.recognizedText(in: image)
            else {
                return
            }

            addMention(
                .file(
                    AISidebarFileContext(
                        name: url.lastPathComponent,
                        text: "Uploaded image OCR text:\n\(recognizedText)"
                    )
                )
            )
            return
        }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
        let trimmed = contents
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excerpt = String(trimmed.prefix(8000))
        guard !excerpt.isEmpty else { return }

        addMention(.file(AISidebarFileContext(name: url.lastPathComponent, text: excerpt)))
    }

    private func recentTurns() -> [CandoaAIConversationTurn] {
        messages.compactMap { message in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CandoaAIConversationTurn(role: message.role.conversationRole, text: text)
        }
    }

    private func cancelStream() {
        streamTask?.cancel()
        streamTask = nil

        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
    }
}

private struct EliSubscriptionGateView: View {
    private static let capabilities = [
        EliSubscriptionCapability(
            title: "Plan a trip",
            detail: "Compare flights and stays, then build a simple itinerary.",
            symbolName: "airplane"
        ),
        EliSubscriptionCapability(
            title: "Shop with confidence",
            detail: "Compare products, prices, and reviews before you buy.",
            symbolName: "cart"
        ),
        EliSubscriptionCapability(
            title: "Catch up on email",
            detail: "Turn a long thread into key takeaways and a reply you can send.",
            symbolName: "envelope"
        ),
        EliSubscriptionCapability(
            title: "Finish the little tasks",
            detail: "Fill a form, find the next step, and keep your day moving.",
            symbolName: "checklist"
        )
    ]

    let accentColor: Color

    @ObservedObject var userStore: UserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCapabilityIndex = 0

    private var selectedCapability: EliSubscriptionCapability {
        Self.capabilities[selectedCapabilityIndex]
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(accentColor)

            VStack(spacing: 6) {
                Text("Meet Eli, your AI agent")
                    .font(.system(size: 18, weight: .semibold))

                Text("Plan, compare, and make progress on the everyday things you do online.")
                    .font(.system(size: 13))
                    .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            capabilityCard
            capabilityPageIndicator

            authenticationOrSubscriptionAction

            if let errorMessage = userStore.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 310)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CandoaChromeStyle.sidebarControlFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CandoaChromeStyle.sidebarControlStroke, lineWidth: 1)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("agent-subscription-gate")
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }

            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }

                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedCapabilityIndex = (selectedCapabilityIndex + 1) % Self.capabilities.count
                }
            }
        }
    }

    @ViewBuilder
    private var authenticationOrSubscriptionAction: some View {
        if userStore.isSignedIn {
            VStack(spacing: 8) {
                Button(userStore.isWorking ? "Opening checkout…" : "Subscribe to Candoa Pro") {
                    Task { await userStore.startProCheckout() }
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(userStore.isWorking)

                Button("Refresh subscription") {
                    Task { await userStore.refresh() }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
                .disabled(userStore.isWorking)
            }
        } else {
            VStack(spacing: 8) {
                SignInWithAppleButton(.continue) { request in
                    userStore.configure(request)
                } onCompletion: { result in
                    userStore.completeAppleSignIn(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 36)
                .disabled(userStore.isWorking)

                Text("Sign in to connect your Candoa subscription and history to this browser.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var capabilityCard: some View {
        ZStack {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedCapability.symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 30, height: 30)
                    .background(accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedCapability.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CandoaChromeStyle.sidebarText)

                    Text(selectedCapability.detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .id(selectedCapability.id)
            .transition(
                reduceMotion
                    ? .identity
                    : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
            )
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(CandoaChromeStyle.sidebarControlFillHover)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(CandoaChromeStyle.sidebarControlStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var capabilityPageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Self.capabilities.indices, id: \.self) { index in
                Circle()
                    .fill(index == selectedCapabilityIndex ? accentColor : CandoaChromeStyle.sidebarIcon)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Eli capability \(selectedCapabilityIndex + 1) of \(Self.capabilities.count)")
    }
}

private struct EliSubscriptionCapability: Identifiable {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let symbolName: String

    var id: String { symbolName }
}
