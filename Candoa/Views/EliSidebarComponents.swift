import AppKit
@preconcurrency import AVFoundation
@preconcurrency import Speech
import SwiftUI

struct AISidebarTopBarIconButton: View {
    let symbolName: String
    let helpText: String
    var iconSize: CGFloat = 15
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: iconSize, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(CandoaChromeStyle.sidebarIcon.opacity(isHovered ? 0.92 : 0.72))
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? CandoaChromeStyle.sidebarControlFillHover : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }
}

struct AISidebarMessageRow: View {
    let message: AISidebarMessage
    let themeColorHex: String?
    @EnvironmentObject private var userStore: UserStore

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser {
                Spacer(minLength: 42)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 7) {
                if isUser, !message.contextChips.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.contextChips.prefix(2)) { chip in
                            AISidebarSentContextChipView(chip: chip)
                        }

                        if message.contextChips.count > 2 {
                            Text("+\(message.contextChips.count - 2)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(CandoaChromeStyle.sidebarControlFill)
                                .clipShape(Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 6) {
                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 13.5))
                            .foregroundStyle(messageForeground)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("No response.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                    }

                    if message.action == .subscribe {
                        Button("Subscribe to Candoa Pro") {
                            Task { await userStore.startProCheckout() }
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 13, weight: .medium))
                        .disabled(userStore.isWorking)
                        .accessibilityIdentifier("agent-subscribe-link")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(messageBackground)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            if !isUser {
                Spacer(minLength: 42)
            }
        }
    }

    private var messageBackground: Color {
        guard isUser else { return CandoaChromeStyle.sidebarControlFill }
        guard let themeColorHex else { return CandoaChromeStyle.sidebarControlFillActive }
        return Color(spaceHex: themeColorHex).opacity(0.82)
    }

    private var messageForeground: Color {
        guard isUser else { return CandoaChromeStyle.sidebarText }
        guard let themeColorHex else { return CandoaChromeStyle.sidebarText }
        return CandoaChromeStyle.prefersDarkForeground(forSpaceHex: themeColorHex)
            ? Color.black.opacity(0.84)
            : Color.white.opacity(0.92)
    }
}

struct AISidebarSentContextChipView: View {
    let chip: AISidebarContextChip

    var body: some View {
        HStack(spacing: 6) {
            AISidebarMentionIcon(symbolName: chip.symbolName, faviconData: chip.faviconData)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(chip.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CandoaChromeStyle.sidebarText)
                    .lineLimit(1)

                if !chip.subtitle.isEmpty {
                    Text(chip.subtitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .frame(maxWidth: 150, alignment: .leading)
        .background(CandoaChromeStyle.sidebarControlFill)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

@MainActor
final class AISidebarSpeechController: ObservableObject {
    @Published private(set) var isListening = false
    @Published private(set) var transcript = ""
    @Published private(set) var statusMessage: String?
    @Published private(set) var elapsedText = "00:00"

    // Do not construct speech or audio capture objects when Eli appears. Creating
    // an audio input graph can cross macOS's microphone privacy boundary, so these
    // exist only for an explicit dictation request.
    private var speechRecognizer: SFSpeechRecognizer?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var elapsedTask: Task<Void, Never>?
    private var startedAt: Date?

    var displayText: String {
        if !transcript.isEmpty {
            return transcript
        }
        return statusMessage ?? "Listening..."
    }

    func startListening() async {
        guard !isListening else { return }

        transcript = ""
        statusMessage = "Listening..."
        elapsedText = "00:00"

        guard await requestSpeechAuthorization() else {
            statusMessage = "Speech recognition is not allowed."
            return
        }

        guard await requestMicrophoneAuthorization() else {
            statusMessage = "Microphone access is not allowed."
            return
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            statusMessage = "Speech recognition is unavailable."
            return
        }

        do {
            try startAudioRecognition(with: recognizer)
        } catch {
            stopAudioRecognition()
            statusMessage = "Could not start dictation."
        }
    }

    @discardableResult
    func stopListening() -> String {
        let finalTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopAudioRecognition()
        statusMessage = nil
        return finalTranscript
    }

    func cancelListening() {
        transcript = ""
        stopAudioRecognition()
        statusMessage = nil
    }

    private func startAudioRecognition(with recognizer: SFSpeechRecognizer) throws {
        stopAudioRecognition()
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        let audioEngine = AVAudioEngine()
        self.audioEngine = audioEngine
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        startedAt = Date()
        startElapsedClock()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stopAudioRecognition()
                }
            }
        }
    }

    private func stopAudioRecognition() {
        if let audioEngine {
            if audioEngine.isRunning {
                audioEngine.stop()
            }
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        audioEngine = nil
        speechRecognizer = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        elapsedTask?.cancel()
        elapsedTask = nil
        startedAt = nil
        isListening = false
    }

    private func startElapsedClock() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self?.updateElapsedText()
                }
            }
        }
    }

    private func updateElapsedText() {
        guard let startedAt else {
            elapsedText = "00:00"
            return
        }

        let elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
        elapsedText = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { isAllowed in
                    continuation.resume(returning: isAllowed)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

struct AISidebarComposerIconButton: View {
    let symbolName: String
    let helpText: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foregroundStyle)
                .frame(width: 28, height: 28)
                .background {
                    Circle()
                        .fill(backgroundFill)
                }
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help(helpText)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var foregroundStyle: Color {
        guard isEnabled else { return CandoaChromeStyle.sidebarIcon.opacity(0.55) }
        return isHovered ? CandoaChromeStyle.sidebarTextSecondary : CandoaChromeStyle.sidebarIcon
    }

    private var backgroundFill: Color {
        guard isEnabled, isHovered else { return Color.clear }
        return CandoaChromeStyle.sidebarControlFillHover
    }
}

struct AISidebarComposerSendButton: View {
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background {
                    Circle()
                        .fill(backgroundFill)
                }
        }
        .buttonStyle(.borderless)
        .disabled(!isEnabled)
        .help("Send to Eli")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var iconColor: Color {
        isEnabled ? Color.black.opacity(0.88) : CandoaChromeStyle.sidebarIcon.opacity(0.58)
    }

    private var backgroundFill: Color {
        guard isEnabled else { return CandoaChromeStyle.sidebarControlFillHover }
        return isHovered ? Color.white.opacity(0.82) : Color.white.opacity(0.96)
    }
}

struct AISidebarSpeechWaveformView: View {
    private let levels: [CGFloat] = [
        0.12, 0.18, 0.10, 0.22, 0.34, 0.16, 0.42, 0.28, 0.58, 0.36,
        0.70, 0.30, 0.44, 0.24, 0.54, 0.20, 0.48, 0.34, 0.64, 0.26,
        0.40, 0.18, 0.32, 0.22, 0.52, 0.30, 0.46, 0.28, 0.68, 0.36,
        0.24, 0.20, 0.38, 0.18, 0.28, 0.14
    ]

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(CandoaChromeStyle.sidebarTextSecondary.opacity(index % 5 == 0 ? 0.86 : 0.72))
                        .frame(width: 1.5, height: max(2, proxy.size.height * levels[index]))
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct AISidebarMentionButton: View {
    let title: String
    let detail: String?
    let symbolName: String
    let faviconData: Data?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AISidebarMentionIcon(symbolName: symbolName, faviconData: faviconData, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : CandoaChromeStyle.sidebarText)
                        .lineLimit(1)

                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.72) : CandoaChromeStyle.sidebarTextSecondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.10)) {
                isHovered = hovering
            }
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return CandoaColor.primary
        }

        return isHovered ? CandoaChromeStyle.sidebarControlFillHover : Color.clear
    }
}

struct AISidebarContextChipView: View {
    let chip: AISidebarContextChip
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isRemoveHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AISidebarMentionIcon(symbolName: chip.symbolName, faviconData: chip.faviconData)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(chip.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CandoaChromeStyle.sidebarText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !chip.subtitle.isEmpty {
                    Text(chip.subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CandoaChromeStyle.sidebarTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: 130, alignment: .leading)
        }
        .padding(.leading, 8)
        .padding(.trailing, 12)
        .frame(height: 46)
        .background(Color.primary.opacity(0.075))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CandoaChromeStyle.sidebarControlStroke, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if chip.isRemovable && isHovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(isRemoveHovered ? Color.black.opacity(0.86) : Color.white.opacity(0.9))
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(isRemoveHovered ? Color.white.opacity(0.96) : Color.white.opacity(0.22))
                        )
                }
                .buttonStyle(.borderless)
                .offset(x: 8, y: -8)
                .help("Remove Context")
                .transition(.opacity)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.10)) {
                        isRemoveHovered = hovering
                    }
                }
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
                if !hovering {
                    isRemoveHovered = false
                }
            }
        }
    }
}

struct AISidebarMentionIcon: View {
    let symbolName: String
    var faviconData: Data?
    var isSelected = false

    var body: some View {
        Group {
            if let faviconData, let image = NSImage(data: faviconData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.86) : CandoaChromeStyle.sidebarIcon)
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct AISidebarMentionOption: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let symbolName: String
    let faviconData: Data?
    let action: AISidebarMentionAction
}

enum AISidebarMentionAction {
    case mention(AISidebarContextMention)
    case uploadFile
}

struct AISidebarContextChip: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let faviconData: Data?
    let isRemovable: Bool
}

enum AISidebarContextMention: Equatable {
    case tab(UUID)
    case history(AISidebarHistoryContext)
    case file(AISidebarFileContext)
}

struct AISidebarHistoryContext: Equatable {
    let id: UUID
    let title: String
    let url: URL
}

struct AISidebarFileContext: Equatable {
    var id = UUID()
    let name: String
    let text: String
}

struct AISidebarMessage: Identifiable, Equatable {
    var id = UUID()
    let role: AISidebarMessageRole
    var text: String
    var isStreaming: Bool
    var contextChips: [AISidebarContextChip] = []
    var action: AISidebarMessageAction? = nil
}

enum AISidebarMessageAction: Equatable {
    case subscribe
}

enum AISidebarMessageRole: Equatable {
    case user
    case assistant

    var conversationRole: CandoaAIConversationTurn.Role {
        switch self {
        case .user:
            return .user
        case .assistant:
            return .assistant
        }
    }
}
