import SwiftUI

internal struct AccountOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @EnvironmentObject private var userStore: UserStore

    // A sign-out relaunch re-presents this gate on its own, outside the
    // first-run flow: there is no earlier step to go back to.
    private var backAction: (() -> Void)? {
        if store.hasCompletedInitialOnboarding { return nil }
        let store = self.store
        return { store.goBackInInitialOnboarding() }
    }

    var body: some View {
        AccountOnboardingSurface(onBack: backAction) {
            VStack(spacing: 0) {
                Spacer(minLength: 20)

                VStack(spacing: 24) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 34, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(InterfaceStyle.decorativeSymbol)

                    VStack(spacing: 10) {
                        Text("Keep your Candoa account with you")
                            .font(.system(size: 30, weight: .semibold))
                            .tracking(-0.4)
                            .multilineTextAlignment(.center)

                        Text(
                            "Sign in with Apple to restore your subscription and use Eli on any Mac."
                        )
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("account-onboarding-description")
                    }

                    VStack(spacing: 12) {
                        Button {
                            userStore.signInWithApple()
                        } label: {
                            HStack(spacing: 8) {
                                if userStore.isSigningInWithApple {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "apple.logo")
                                    Text("Continue with Apple")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonTreatment(.primary)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                        .keyboardShortcut(.defaultAction)
                        .disabled(userStore.isWorking)
                        .accessibilityIdentifier("onboarding-sign-in-apple")

                        if let errorMessage = userStore.errorMessage, !userStore.isWorking {
                            Text(errorMessage)
                                .font(.system(size: 12))
                                .foregroundStyle(AppColor.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Button("Not Now") {
                            userStore.continueOnThisMac()
                        }
                        .buttonTreatment(.quiet)
                        .controlSize(.large)
                        .disabled(userStore.isWorking)
                        .accessibilityIdentifier("onboarding-not-now")
                    }
                }

                Spacer(minLength: 20)
            }
            .frame(maxWidth: 310)
        }
        .onChange(of: userStore.hasCompletedAccountChoice) { _, hasCompletedAccountChoice in
            if hasCompletedAccountChoice {
                store.completeInitialAccountSetup()
            }
        }
        .accessibilityValue(userStore.isWorking ? "signing-in" : "idle")
        .accessibilityIdentifier("account-onboarding")
    }
}

private struct AccountOnboardingSurface<Content: View>: View {
    private static var step: InitialOnboardingStep { .account }

    let onBack: (() -> Void)?
    @ViewBuilder let content: Content

    init(
        onBack: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let cardWidth = min(560, max(440, proxy.size.width - 64))
            let cardHeight = min(580, max(500, proxy.size.height - 64))

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if let onBack {
                        Button(action: onBack) {
                            Label("Back", systemImage: "chevron.left")
                        }
                        .buttonTreatment(.quiet)
                        .font(.system(size: 12, weight: .semibold))
                        .help("Back")
                        .accessibilityIdentifier("onboarding-back")

                        Spacer()

                        Text("\(Self.step.position) of \(Self.step.count)")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 44)
            }
            .padding(38)
            .frame(width: cardWidth, height: cardHeight)
            .background(InterfaceStyle.surfaceFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 30, y: 14)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .background(InterfaceStyle.surfaceFill.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("initial-onboarding-account")
        .accessibilityValue(
            onBack != nil
                ? "Step \(Self.step.position) of \(Self.step.count)"
                : "Account"
        )
    }
}
