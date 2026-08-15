import SwiftUI

extension InitialTourTip {
    var symbolName: String {
        switch self {
        case .commandBar: "command"
        case .spaces: "square.stack.3d.up"
        case .ask: "sparkles"
        }
    }

    var title: String {
        switch self {
        case .commandBar: String(localized: "Find anything quickly")
        case .spaces: String(localized: "Keep contexts separate")
        case .ask: String(localized: "Understand any page")
        }
    }

    var detail: String {
        switch self {
        case .commandBar:
            String(localized: "Press Command-T to search the web, open a site, or jump to an existing tab.")
        case .spaces:
            String(localized: "Spaces separate work, projects, research, and personal browsing without losing your tabs.")
        case .ask:
            String(localized: "Press Command-E to open Eli and summarize, explain, compare, or identify next steps without leaving the page.")
        }
    }

    var shortcut: String {
        switch self {
        case .commandBar: "⌘T"
        case .spaces: "⌃1–9"
        case .ask: "⌘E"
        }
    }

    var accessibilityShortcutLabel: String {
        switch self {
        case .commandBar: String(localized: "Keyboard shortcut: Command-T")
        case .spaces: String(localized: "Keyboard shortcut: Control-1 through 9")
        case .ask: String(localized: "Keyboard shortcut: Command-E")
        }
    }

    var identifier: String {
        switch self {
        case .commandBar: "command-bar"
        case .spaces: "spaces"
        case .ask: "ask"
        }
    }
}

private struct InitialTourPopover: View {
    @ObservedObject var store: BrowserStore
    let tip: InitialTourTip

    private var isFirstTip: Bool { tip == InitialTourTip.allCases.first }
    private var isLastTip: Bool { tip == InitialTourTip.allCases.last }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: tip.symbolName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.decorativeSymbol)
                    .frame(width: 28, height: 28)

                Text(tip.title)
                    .font(.headline)

                Spacer(minLength: 8)

                Text(tip.shortcut)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(tip.accessibilityShortcutLabel))
            }

            Text(tip.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(String(localized: "Skip Tour")) {
                    store.completeInitialTour()
                }
                .buttonTreatment(.quiet)

                Spacer()

                if !isFirstTip {
                    Button(String(localized: "Back")) {
                        store.showPreviousInitialTourTip()
                    }
                    .buttonTreatment(.secondary)
                }

                Button(isLastTip ? String(localized: "Done") : String(localized: "Next")) {
                    store.showNextInitialTourTip()
                }
                .buttonTreatment(.primary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 330)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(tip.title))
        .accessibilityIdentifier("initial-tour-\(tip.identifier)")
    }
}

private struct InitialTourPopoverModifier: ViewModifier {
    @ObservedObject var store: BrowserStore
    let tip: InitialTourTip
    let arrowEdge: Edge

    func body(content: Content) -> some View {
        content.popover(
            isPresented: Binding(
                get: { store.initialTourTip == tip },
                set: { isPresented in
                    if !isPresented, store.initialTourTip == tip {
                        store.completeInitialTour()
                    }
                }
            ),
            arrowEdge: arrowEdge
        ) {
            InitialTourPopover(store: store, tip: tip)
        }
    }
}

extension View {
    func initialTourPopover(
        _ tip: InitialTourTip,
        store: BrowserStore,
        arrowEdge: Edge
    ) -> some View {
        modifier(InitialTourPopoverModifier(store: store, tip: tip, arrowEdge: arrowEdge))
    }
}
