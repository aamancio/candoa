import AppKit
import SwiftUI

internal struct AddressBarOnboardingStep: View {
    @ObservedObject var store: BrowserStore
    @State private var selection: AddressBarPlacement = .current

    var body: some View {
        OnboardingSurface(step: .addressBar, onBack: store.goBackInInitialOnboarding) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "rectangle.topthird.inset.filled",
                    title: String(localized: "Where should the toolbar live?"),
                    detail: String(localized: "Candoa keeps the address and its controls in the sidebar so pages get the whole window. If you’d rather always see them above the page, choose that here.")
                )

                VStack(spacing: 10) {
                    ForEach(AddressBarPlacement.allCases, id: \.self) { placement in
                        AddressBarPlacementCard(
                            placement: placement,
                            isSelected: selection == placement
                        ) {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                selection = placement
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding-address-bar-options")

                Text("You can change this anytime in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button {
                    store.completeInitialAddressBarSetup(placement: selection)
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonTreatment(.primary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-address-bar-continue")
            }
        } preview: {
            VStack(spacing: 22) {
                Spacer(minLength: 0)

                AddressBarPlacementMockup(placement: selection, emphasized: true)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .frame(maxWidth: 440)
                    .accessibilityHidden(true)

                Text(selection.onboardingCaption)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .id(selection)
                    .transition(.opacity)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension AddressBarPlacement {
    var onboardingTitle: String {
        switch self {
        case .sidebar: return String(localized: "In the sidebar")
        case .top: return String(localized: "Above the page")
        }
    }

    var onboardingDetail: String {
        switch self {
        case .sidebar: return String(localized: "Clean and focused. Click the sidebar pill or press ⌘L to go somewhere.")
        case .top: return String(localized: "Always in view. A slim toolbar above every page holds the address and its controls.")
        }
    }

    var onboardingCaption: String {
        switch self {
        case .sidebar: return String(localized: "The address and its controls sit with your tabs, and pages get the whole window.")
        case .top: return String(localized: "Back, forward, reload, and the address stay above the page, like a classic browser.")
        }
    }
}

/// One selectable option: a small window mockup beside the placement's name
/// and a one-line description, with a radio-style check when chosen.
private struct AddressBarPlacementCard: View {
    let placement: AddressBarPlacement
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AddressBarPlacementMockup(placement: placement, emphasized: isSelected)
                    .frame(width: 92, height: 58)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(placement.onboardingTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(placement.onboardingDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSelected ? AppColor.accent : Color.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? AppColor.accent.opacity(0.08)
                    : Color(nsColor: .controlBackgroundColor).opacity(0.42),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(
                        isSelected ? AppColor.accent.opacity(0.5) : InterfaceStyle.surfaceBorder,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(placement.onboardingTitle)
        .accessibilityValue(isSelected ? String(localized: "Selected") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("onboarding-address-bar-\(placement.rawValue)")
    }
}

/// A schematic Candoa window: sidebar lane with traffic lights and tab rows,
/// page area with placeholder lines, and the address element drawn where the
/// placement puts it — a pill in the sidebar or a strip across the page top.
/// Everything is proportional so the same drawing reads at 92pt and 440pt.
private struct AddressBarPlacementMockup: View {
    let placement: AddressBarPlacement
    let emphasized: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let unit = width / 100
            let sidebarWidth = width * 0.30
            let inset = unit * 3
            let addressColor = emphasized ? AppColor.accent : Color.secondary.opacity(0.55)
            let rowColor = Color.primary.opacity(0.10)
            let cornerRadius = unit * 5

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))

                // Sidebar lane.
                VStack(alignment: .leading, spacing: unit * 3) {
                    HStack(spacing: unit * 1.6) {
                        ForEach(0..<3, id: \.self) { index in
                            Circle()
                                .fill(Self.trafficLightColors[index].opacity(0.85))
                                .frame(width: unit * 2.4, height: unit * 2.4)
                        }

                        Spacer(minLength: 0)

                        if placement == .sidebar {
                            controlGlyphs(color: addressColor, unit: unit)
                        }
                    }
                    .padding(.top, unit * 0.5)

                    if placement == .sidebar {
                        addressElement(color: addressColor, cornerRadius: unit * 2.2)
                            .frame(height: unit * 6)
                    }

                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: unit * 1.4, style: .continuous)
                            .fill(rowColor)
                            .frame(width: (sidebarWidth - inset * 2) * (index == 0 ? 0.9 : 0.72), height: unit * 3.4)
                    }
                }
                .padding(inset)
                .frame(width: sidebarWidth, height: height, alignment: .topLeading)
                .background(
                    InterfaceStyle.sidebarControlFill.opacity(0.9),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: cornerRadius,
                        bottomLeadingRadius: cornerRadius,
                        style: .continuous
                    )
                )

                // Page area.
                VStack(alignment: .leading, spacing: 0) {
                    if placement == .top {
                        HStack(spacing: unit * 2) {
                            controlGlyphs(color: addressColor, unit: unit)
                            addressElement(color: addressColor, cornerRadius: unit * 1.6)
                                .frame(height: unit * 5)
                        }
                            .padding(.horizontal, unit * 2)
                            .padding(.vertical, unit * 1.6)
                            .background(Color.primary.opacity(0.04))
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: max(1, unit * 0.4))
                    }

                    VStack(alignment: .leading, spacing: unit * 3) {
                        RoundedRectangle(cornerRadius: unit * 1.4, style: .continuous)
                            .fill(rowColor)
                            .frame(width: (width - sidebarWidth) * 0.42, height: unit * 4.5)
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: unit * 1.2, style: .continuous)
                                .fill(rowColor.opacity(0.7))
                                .frame(width: (width - sidebarWidth) * (index == 2 ? 0.5 : 0.78), height: unit * 2.6)
                        }
                    }
                    .padding(unit * 5)
                }
                .frame(width: width - sidebarWidth, height: height, alignment: .topLeading)
                .offset(x: sidebarWidth)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(emphasized ? 0.10 : 0.04), radius: unit * 3, y: unit * 1.2)
        }
    }

    private static let trafficLightColors: [Color] = [
        Color(red: 1.0, green: 0.37, blue: 0.34),
        Color(red: 1.0, green: 0.74, blue: 0.18),
        Color(red: 0.16, green: 0.79, blue: 0.26)
    ]

    /// Back, forward, and reload, drawn as three short strokes: at 92pt wide
    /// the real glyphs would be mud, but their count and placement is what
    /// tells the two placements apart.
    private func controlGlyphs(color: Color, unit: CGFloat) -> some View {
        HStack(spacing: unit * 1.4) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule(style: .continuous)
                    .fill(color.opacity(0.55))
                    .frame(width: unit * 2.2, height: unit * 1.1)
            }
        }
    }

    /// The address glyph: a filled capsule with a small lock dot at its start.
    private func addressElement(color: Color, cornerRadius: CGFloat) -> some View {
        GeometryReader { proxy in
            let h = proxy.size.height
            HStack(spacing: h * 0.3) {
                Circle()
                    .fill(color.opacity(0.9))
                    .frame(width: h * 0.34, height: h * 0.34)
                RoundedRectangle(cornerRadius: h * 0.2, style: .continuous)
                    .fill(color.opacity(0.75))
                    .frame(width: proxy.size.width * 0.5, height: h * 0.28)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, h * 0.35)
            .frame(width: proxy.size.width, height: h)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(color.opacity(0.55), lineWidth: 1)
            }
        }
    }
}
