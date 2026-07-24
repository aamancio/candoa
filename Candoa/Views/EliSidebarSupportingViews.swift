import AppKit
import SwiftUI

struct BrowserAgentRunState: Sendable {
    let runID: UUID
    let goal: String
    let tabID: UUID
    let responseID: UUID
}

struct PendingBrowserControl: Sendable {
    let goal: String
    let tabID: UUID?
}

struct PendingSensitiveAgentAction: Identifiable, Sendable {
    let id = UUID()
    let action: CandoaPageActionProposal
    let state: BrowserAgentRunState
    let previousURL: String
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
                .candoaButton(.content)
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
