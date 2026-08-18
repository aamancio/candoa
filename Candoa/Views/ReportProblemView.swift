import SwiftUI

/// Help ▸ Report an Issue…
///
/// The window states plainly what it will send before anyone types, because a
/// report from a browser is only trustworthy if the person can see it carries
/// nothing about their browsing. Their words, the app version, and the macOS
/// version are the whole payload.
struct ReportProblemView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var state: SubmissionState = .editing
    @State private var alsoShareCrashes = ProblemReportConsent.isEnabled
    @FocusState private var isEditorFocused: Bool

    private enum SubmissionState: Equatable {
        case editing
        case sending
        case sent
        case failed
    }

    private var trimmedDescription: String {
        description.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if state == .sent {
                sentContent
            } else {
                editingContent
            }
        }
        .frame(width: 460)
        .accessibilityIdentifier("report-problem-view")
    }

    private var editingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What went wrong?")
                .font(.system(size: 15, weight: .semibold))

            Text("Describe what you were doing and what you expected to happen.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextEditor(text: $description)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor))
                )
                .focused($isEditorFocused)
                .accessibilityIdentifier("report-problem-description")

            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "Your report includes Candoa's version and your macOS version.",
                    systemImage: "info.circle"
                )
                Label(
                    "It never includes the pages you visited, your tabs, or your history.",
                    systemImage: "lock"
                )
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Toggle("Also send crash reports automatically", isOn: $alsoShareCrashes)
                .font(.system(size: 12))
                .onChange(of: alsoShareCrashes) { _, newValue in
                    ProblemReportConsent.isEnabled = newValue
                }
                .accessibilityIdentifier("report-problem-share-crashes")

            if state == .failed {
                Text("Your report could not be sent. Check your connection and try again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityIdentifier("report-problem-error")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Send") { send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedDescription.isEmpty || state == .sending)
                    .accessibilityIdentifier("report-problem-send")
            }
        }
        .padding(20)
        .onAppear { isEditorFocused = true }
    }

    private var sentContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Color(nsColor: .systemGreen))

            Text("Thank you.")
                .font(.system(size: 15, weight: .semibold))

            Text("Your report is on its way.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .accessibilityIdentifier("report-problem-sent")
    }

    private func send() {
        let text = trimmedDescription
        guard !text.isEmpty else { return }
        state = .sending
        Task {
            do {
                try await ProblemReportSubmitter.shared.submitWritten(description: text)
                state = .sent
            } catch {
                state = .failed
            }
        }
    }
}
