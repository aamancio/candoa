import SwiftUI

/// Semantic treatments for Candoa actions. Each treatment delegates rendering,
/// interaction, focus, accessibility, and platform adaptation to SwiftUI.
enum ButtonTreatment {
    /// The single emphasized action in a view or task.
    case primary

    /// A visible alternative that should not compete with the primary action.
    case secondary

    /// A low-emphasis text action such as Skip or Not Now.
    case quiet

    /// Navigation or help presented using the system link treatment.
    case link

    /// Compact window, toolbar, or sidebar chrome.
    case chrome

    /// A fully composed row, card, or icon button whose label owns its
    /// appearance while SwiftUI continues to own button behavior.
    case content
}

extension View {
    /// Applies Candoa's semantic intent while preserving the native macOS
    /// control. Apply it to a `Button`, or to a container when every descendant
    /// button shares the same intent. Layout and `controlSize` remain explicit
    /// at the call site.
    @MainActor
    @ViewBuilder
    func buttonTreatment(_ treatment: ButtonTreatment) -> some View {
        switch treatment {
        case .primary:
            buttonStyle(.borderedProminent)
        case .secondary:
            buttonStyle(.bordered)
        case .quiet:
            buttonStyle(.plain)
                .foregroundStyle(.secondary)
        case .link:
            buttonStyle(.link)
        case .chrome:
            buttonStyle(.borderless)
        case .content:
            buttonStyle(.plain)
        }
    }
}
