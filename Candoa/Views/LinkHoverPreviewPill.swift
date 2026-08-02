import SwiftUI

/// Arc/Chrome-style transient destination preview: a small pill over the
/// page's bottom-leading corner that exists only while a link is hovered.
/// No persistent status bar — no reserved layout space, nothing to toggle.
struct LinkHoverPreviewPill: View {
    let urlString: String

    /// HTTPS is the unremarkable default, so it is elided; every other
    /// scheme (http, javascript, mailto, file) stays visible precisely
    /// because it is information. The origin leads and truncation eats the
    /// middle, so host and destination tail both survive long URLs.
    private var displayText: String {
        if let stripped = urlString.range(of: "https://").flatMap({ range in
            range.lowerBound == urlString.startIndex ? String(urlString[range.upperBound...]) : nil
        }) {
            return stripped
        }
        return urlString
    }

    var body: some View {
        Text(displayText)
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(CandoaInterfaceStyle.popoverBorder, lineWidth: 1)
            }
            .shadow(color: Color(nsColor: .shadowColor).opacity(0.14), radius: 6, y: 2)
            // Outside the background: caps long URLs (middle truncation
            // keeps host and tail) while short ones hug their text instead
            // of stretching the pill to the cap.
            .frame(maxWidth: 560, alignment: .leading)
            // Purely visual for sighted pointer users; keyboard and
            // VoiceOver users get link destinations from WebKit's own
            // accessibility tree (AXURL), so exposing this transient copy
            // would only produce duplicate chatter.
            .accessibilityHidden(true)
    }
}
