import AppKit
import SwiftUI

struct AISidebarMessageRow: View {
    @Binding var message: AISidebarMessage
    /// Resolve a `waitingForUser` card; supplied only by the Eli sidebar,
    /// which owns the run lifecycle.
    var onWaitingContinue: (() -> Void)? = nil
    var onWaitingStop: (() -> Void)? = nil
    @EnvironmentObject private var userStore: UserStore
    @State private var didCopyText = false

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        if isUser {
            HStack(alignment: .top) {
                Spacer(minLength: 42)

                VStack(alignment: .trailing, spacing: 7) {
                    sentContextChips
                    userPrompt
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                messageContent

                if showsFeedbackControls {
                    feedbackControls
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 8)
        }
    }

    @ViewBuilder
    private var sentContextChips: some View {
        if !message.contextChips.isEmpty {
            HStack(spacing: 6) {
                ForEach(message.contextChips.prefix(2)) { chip in
                    AISidebarSentContextChipView(chip: chip)
                }

                if message.contextChips.count > 2 {
                    Text("+\(message.contextChips.count - 2)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(InterfaceStyle.sidebarControlFill)
                        .clipShape(Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var userPrompt: some View {
        messageContent
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(maxWidth: 350, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(messageBackground)
            }
            .accessibilityIdentifier("user-message-bubble")
    }

    @ViewBuilder
    private var messageContent: some View {
        if message.action == .subscribe {
            AISidebarSubscriptionGateView()
        } else if case let .waitingForUser(reason) = message.action {
            AISidebarWaitingCardView(
                reason: reason,
                onContinue: { onWaitingContinue?() },
                onStop: { onWaitingStop?() }
            )
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.system(size: 14))
                        .foregroundStyle(messageForeground)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let image = message.responseImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 420)
                        .accessibilityLabel("Response image")
                }

                if !message.hasCopyableContent && message.isStreaming {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)

                        if let transientStatus = message.transientStatus {
                            Text(transientStatus)
                                .font(.system(size: 13.5))
                                .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent-activity-status")
                } else if !message.hasCopyableContent {
                    Text("No response.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                }
            }
        }
    }

    private var showsFeedbackControls: Bool {
        message.action == nil && !message.isStreaming && message.hasCopyableContent
    }

    private var feedbackControls: some View {
        HStack(spacing: 8) {
            feedbackButton(
                feedback: .positive,
                symbolName: "hand.thumbsup",
                helpText: "Good response",
                identifier: "agent-feedback-up"
            )

            feedbackButton(
                feedback: .negative,
                symbolName: "hand.thumbsdown",
                helpText: "Poor response",
                identifier: "agent-feedback-down"
            )

            if !message.text.isEmpty {
                responseActionButton(
                    symbolName: didCopyText ? "checkmark" : "doc.on.doc",
                    helpText: didCopyText ? "Copied" : "Copy as text",
                    accessibilityLabel: didCopyText ? "Response copied as text" : "Copy response as text",
                    identifier: "agent-copy-text",
                    isSelected: didCopyText,
                    action: copyResponseText
                )
                .task(id: didCopyText) {
                    guard didCopyText else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    didCopyText = false
                }
            }

            if message.responseImage != nil {
                responseActionButton(
                    symbolName: "photo",
                    helpText: "Copy image",
                    accessibilityLabel: "Copy response image",
                    identifier: "agent-copy-image",
                    action: copyResponseImage
                )
            }
        }
    }

    private func feedbackButton(
        feedback: AISidebarResponseFeedback,
        symbolName: String,
        helpText: String,
        identifier: String
    ) -> some View {
        AISidebarNativeIconButton(
            symbolName: symbolName,
            toolTip: helpText,
            accessibilityLabel: feedback == .positive ? "Good response" : "Poor response",
            identifier: identifier,
            isSelected: message.feedback == feedback
        ) {
            message.feedback = message.feedback == feedback ? nil : feedback
        }
        .frame(width: 22, height: 22)
    }

    private func responseActionButton(
        symbolName: String,
        helpText: String,
        accessibilityLabel: String,
        identifier: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        AISidebarNativeIconButton(
            symbolName: symbolName,
            toolTip: helpText,
            accessibilityLabel: accessibilityLabel,
            identifier: identifier,
            isSelected: isSelected,
            action: action
        )
        .frame(width: 22, height: 22)
    }

    private func copyResponseText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(message.text, forType: .string)
        didCopyText = true
    }

    private func copyResponseImage() {
        guard let image = message.responseImage else {
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private var messageBackground: Color {
        guard isUser else { return InterfaceStyle.sidebarControlFill }
        return InterfaceStyle.userMessageFill
    }

    private var messageForeground: Color {
        guard isUser else { return InterfaceStyle.sidebarText }
        return InterfaceStyle.userMessageText
    }

}

/// Rendered inside an assistant message while a browser-agent run is paused
/// on something only the user can clear (an ad, a sign-in, a CAPTCHA). The
/// run stays alive until Continue or Stop resolves it.
struct AISidebarWaitingCardView: View {
    let reason: String
    let onContinue: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Waiting for you")
                    .font(.system(size: 14, weight: .semibold))
            }
            .accessibilityElement(children: .combine)

            Text(reason)
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("agent-waiting-continue")

                Button("Stop", action: onStop)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("agent-waiting-stop")
            }
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: 350, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        }
        // .contain keeps this a plain AX container: an element-style
        // identifier here would swallow the buttons' own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agent-waiting-card")
    }
}
