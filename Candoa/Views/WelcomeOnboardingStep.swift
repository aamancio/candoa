import AppKit
import SwiftUI

struct WelcomeToCandoaPage: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsContent = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 72, height: 72)

                        Text(String(localized: "Welcome to Candoa"))
                            .font(.system(size: 30, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)

                        Text(String(localized: "Your browser is ready. Here are three essentials to help you get started."))
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    HStack(alignment: .top, spacing: 14) {
                        welcomeFeature(
                            title: String(localized: "Find anything quickly"),
                            detail: String(localized: "Search, open a site, or jump to a tab with Command-T."),
                            symbolName: "command"
                        )
                        welcomeFeature(
                            title: String(localized: "Keep contexts separate"),
                            detail: String(localized: "Use Spaces for work, projects, research, and personal browsing."),
                            symbolName: "square.stack.3d.up"
                        )
                        welcomeFeature(
                            title: String(localized: "Understand any page"),
                            detail: String(localized: "Open Eli with Command-E without changing apps."),
                            symbolName: "sparkles"
                        )
                    }
                }
                .padding(48)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .opacity(revealsContent ? 1 : 0)
                .offset(y: reduceMotion || revealsContent ? 0 : 8)
            }
        }
        .background(InterfaceStyle.surfaceFill.opacity(0.72))
        .accessibilityIdentifier("welcome-to-candoa-page")
        .onAppear {
            guard !revealsContent else { return }

            if reduceMotion {
                revealsContent = true
                store.startInitialTour()
            } else {
                withAnimation(.easeOut(duration: 0.22)) {
                    revealsContent = true
                } completion: {
                    store.startInitialTour()
                }
            }
        }
    }

    private func welcomeFeature(
        title: String,
        detail: String,
        symbolName: String
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: symbolName)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(InterfaceStyle.decorativeSymbol)

                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }
}

internal struct WelcomeOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsFirstLine = false
    @State private var revealsSecondLine = false
    @State private var revealsAction = false

    var body: some View {
        ZStack {
            VStack(spacing: 4) {
                Text("Your browser, organized")
                    .opacity(revealsFirstLine ? 1 : 0)
                    .offset(y: revealsFirstLine ? 0 : 12)

                Text("around your life.")
                    .foregroundStyle(.secondary)
                    .opacity(revealsSecondLine ? 1 : 0)
                    .offset(y: revealsSecondLine ? 0 : 12)
            }
            .font(.system(size: 58, weight: .semibold))
            .tracking(-1.6)
            .multilineTextAlignment(.center)

            VStack {
                Spacer()

                Button {
                    store.completeInitialWelcome()
                } label: {
                    Label("Begin Setup", systemImage: "arrow.right")
                        .frame(minWidth: 116)
                }
                .buttonTreatment(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .opacity(revealsAction ? 1 : 0)
                .offset(y: revealsAction ? 0 : 8)
                .accessibilityIdentifier("onboarding-get-started")
                .padding(.bottom, 62)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(InterfaceStyle.surfaceFill)
        .accessibilityIdentifier("initial-onboarding-welcome")
        .task {
            guard !revealsAction else { return }
            if reduceMotion {
                revealsFirstLine = true
                revealsSecondLine = true
                revealsAction = true
                return
            }

            withAnimation(.easeOut(duration: 0.20)) {
                revealsFirstLine = true
            }
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                revealsSecondLine = true
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                revealsAction = true
            }
        }
    }
}
