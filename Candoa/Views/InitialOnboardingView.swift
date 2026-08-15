import SwiftUI

struct InitialOnboardingCanvas: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        switch store.initialOnboardingStep {
        case .welcome:
            WelcomeOnboardingStep(store: store)
        case .account:
            AccountOnboardingStep(store: store)
        case .importData:
            ImportOnboardingStep(store: store)
        case .space:
            SpaceOnboardingStep(store: store)
        case .addressBar:
            AddressBarOnboardingStep(store: store)
        case .restoredWorkspace:
            RestoredWorkspaceOnboardingStep(store: store)
        case .tour, .none:
            EmptyView()
        }
    }
}

private struct RestoredWorkspaceOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsContent = false

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 14) {
                Image(systemName: "checkmark.icloud")
                    .font(.system(size: 44, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(InterfaceStyle.decorativeSymbol)

                Text("Welcome back")
                    .font(.system(size: 34, weight: .semibold))
                    .tracking(-0.6)
                    .accessibilityAddTraits(.isHeader)

                Text("iCloud restored your Spaces and tabs, so this Mac can pick up right where you left off.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            Button {
                store.completeRestoredWorkspaceWelcome()
            } label: {
                Label("Start Browsing", systemImage: "arrow.right")
                    .frame(minWidth: 136)
            }
            .buttonTreatment(.primary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding-start-browsing")
        }
        .padding(48)
        .opacity(revealsContent ? 1 : 0)
        .offset(y: reduceMotion || revealsContent ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InterfaceStyle.surfaceFill)
        .accessibilityIdentifier("initial-onboarding-restoredWorkspace")
        .onAppear {
            guard !revealsContent else { return }

            if reduceMotion {
                revealsContent = true
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    revealsContent = true
                }
            }
        }
    }
}

// MARK: - Address bar placement
