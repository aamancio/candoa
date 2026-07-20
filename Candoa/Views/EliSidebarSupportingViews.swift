import AppKit
import SwiftUI

struct BrowserAgentRunState: Sendable {
    let goal: String
    let tabID: UUID
    var history: [CandoaBrowserAgentHistoryItem]
    var stepCount: Int
    let responseID: UUID
}

enum PendingBrowserControl: Sendable {
    case action(CandoaPageActionProposal, tabID: UUID?)
    case agent(goal: String, tabID: UUID?)
}

struct PendingSensitiveAgentAction: Identifiable, Sendable {
    let id = UUID()
    let action: CandoaPageActionProposal
    let state: BrowserAgentRunState
}

struct SuggestedPageAction {
    let action: CandoaPageActionProposal
    let tabID: UUID?
    let pageURL: String?
}

struct AISidebarImagePreview: Identifiable {
    let id = UUID()
    let title: String
    let imageData: Data
}

struct AISidebarImagePreviewSheet: View {
    let preview: AISidebarImagePreview
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(preview.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                }
                .buttonStyle(.plain)
                .help("Close Preview")
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close image preview")
            }

            if let image = NSImage(data: preview.imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityLabel("Attached image preview")
            }
        }
        .padding(16)
        .frame(width: 720, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("agent-image-preview-dialog")
    }
}

struct EliTourPreviewView: View {
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Example"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(accentColor.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "Get answers and take action"))
                    .font(.system(size: 17, weight: .semibold))

                Text(String(localized: "Ask about the page, draft a reply, or get help with a page action."))
                    .font(.system(size: 12.5))
                    .foregroundStyle(CandoaInterfaceStyle.sidebarTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(String(localized: "Subscription Settings"), systemImage: "gearshape")
                            .font(.system(size: 12.5, weight: .semibold))

                        Spacer()

                        Text(String(localized: "$19.99/mo"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Text(String(localized: "Your plan renews August 3. Manage or cancel it from your account."))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accentColor)

                Text(String(localized: "How do I cancel this subscription?"))
                    .font(.system(size: 12.5, weight: .medium))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "Eli"), systemImage: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(accentColor)

                stepRow(String(localized: "Open Account Settings"), number: 1)
                stepRow(String(localized: "Choose Billing"), number: 2)
                stepRow(String(localized: "Select Cancel Subscription"), number: 3)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CandoaInterfaceStyle.sidebarControlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(CandoaInterfaceStyle.sidebarControlStroke, lineWidth: 1)
            }
        }
        .frame(maxWidth: 340)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "Eli example")))
        .accessibilityIdentifier("agent-tour-preview")
    }

    private func stepRow(_ title: String, number: Int) -> some View {
        Label(title, systemImage: "\(number).circle.fill")
            .font(.system(size: 12, weight: .medium))
            .symbolRenderingMode(.hierarchical)
    }
}

