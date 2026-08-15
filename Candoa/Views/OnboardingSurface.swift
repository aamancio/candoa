import SwiftUI

internal struct OnboardingSurface<Leading: View, Preview: View>: View {
    let step: InitialOnboardingStep
    let onBack: (() -> Void)?
    @ViewBuilder let leading: Leading
    @ViewBuilder let preview: Preview

    init(
        step: InitialOnboardingStep,
        onBack: (() -> Void)? = nil,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder preview: () -> Preview
    ) {
        self.step = step
        self.onBack = onBack
        self.leading = leading()
        self.preview = preview()
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(720, proxy.size.width - 64)
            let availableHeight = max(480, proxy.size.height - 64)
            let cardWidth = min(1080, availableWidth)
            let cardHeight = min(680, availableHeight)
            let leadingWidth = min(430, max(330, cardWidth * 0.40))

            HStack(spacing: 0) {
                setupRail(width: leadingWidth)
                previewRail
            }
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
        .accessibilityIdentifier("initial-onboarding-\(step.rawValue)")
        .accessibilityValue("Step \(step.position) of \(step.count)")
    }

    private func setupRail(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            setupProgressLabel
                .padding(.bottom, 34)

            leading
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(38)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .leading)
    }

    private var setupProgressLabel: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonTreatment(.quiet)
                .font(.system(size: 12, weight: .semibold))
                .help("Back")
                .accessibilityIdentifier("onboarding-back")
            } else {
                Text("Set up your workflow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(step.position) of \(step.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
        }
    }

    private var previewRail: some View {
        preview
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(InterfaceStyle.sidebarControlFill.opacity(0.50))
    }
}

internal struct OnboardingPageHeader: View {
    let symbolName: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: symbolName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(InterfaceStyle.decorativeSymbol)

            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.4)

            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
