import SwiftUI

struct AISidebarSubscriptionGateView: View {
    @EnvironmentObject private var userStore: UserStore

    var body: some View {
        let isSubscribing = userStore.isStartingSubscription
        let isSigningIn = userStore.isSigningInWithApple
        let isPending = userStore.isAwaitingSubscriptionActivation
        let isConfirming = userStore.isReconcilingSubscription
        let requiresSignIn = userStore.status?.hasAppleAccount != true

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    requiresSignIn ? "Sign in to use Eli" : "Eli with Candoa Pro",
                    systemImage: "lock.fill"
                )
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .accessibilityIdentifier("agent-subscription-gate")

                Text(
                    requiresSignIn
                        ? "Sign in with Apple to restore your Candoa subscription on this Mac."
                        : "Summarize pages, answer questions, and let Eli research and take action across the web."
                )
                    .font(.system(size: 13.5))
                    .foregroundStyle(InterfaceStyle.sidebarTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isConfirming {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Confirming subscription…")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("agent-subscription-confirming")
                } else if isPending {
                    Button("Check Again") {
                        Task {
                            await userStore.reconcilePendingSubscriptionIfNeeded()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(userStore.isWorking)
                    .accessibilityIdentifier("agent-subscription-check-button")
                } else if requiresSignIn {
                    Button {
                        userStore.signInWithApple()
                    } label: {
                        HStack(spacing: 7) {
                            if isSigningIn {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if !isSigningIn {
                                Image(systemName: "apple.logo")
                            }
                            Text(isSigningIn ? "Signing In…" : "Sign In with Apple")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSigningIn || userStore.isWorking)
                    .accessibilityLabel(isSigningIn ? "Signing In" : "Sign In with Apple")
                    .accessibilityValue(isSigningIn ? "signing-in" : "idle")
                    .accessibilityIdentifier("agent-sign-in-button")
                } else {
                    Button {
                        Task { await userStore.startProCheckout() }
                    } label: {
                        HStack(spacing: 7) {
                            if isSubscribing {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(isSubscribing ? "Subscribing…" : "Subscribe")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isSubscribing || userStore.isWorking)
                    .accessibilityLabel(isSubscribing ? "Subscribing" : "Subscribe")
                    .accessibilityValue(isSubscribing ? "subscribing" : "idle")
                    .accessibilityIdentifier("agent-subscribe-button")
                }

                if let accessErrorMessage = requiresSignIn
                    ? userStore.errorMessage
                    : userStore.subscriptionErrorMessage,
                   !isSubscribing,
                   !isSigningIn,
                   !isConfirming {
                    Label(
                        accessErrorMessage,
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(accessErrorMessage)
                    .accessibilityIdentifier("agent-subscribe-error")
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
