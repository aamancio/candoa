import SwiftUI

/// Help ▸ Acknowledgments: the open-source notices from the bundled
/// Credits.rtf, the same file the standard About panel renders. License text
/// is a legal notice, so it is shown verbatim and never localized.
struct AcknowledgmentsView: View {
    var body: some View {
        ScrollView {
            Text(Self.credits)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 460, minHeight: 380)
        .accessibilityIdentifier("acknowledgments-view")
    }

    /// Credits.rtf converted once; the window is small and the file static.
    private static let credits: AttributedString = {
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "rtf"),
           let attributed = try? NSAttributedString(
               url: url,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil
           ) {
            return AttributedString(attributed)
        }

        // The bundle should always carry the file; if it does not, name the
        // software anyway rather than showing an empty window.
        return AttributedString(
            """
            Candoa includes the following open-source software:

            Sparkle
            https://github.com/sparkle-project/Sparkle
            """
        )
    }()
}
