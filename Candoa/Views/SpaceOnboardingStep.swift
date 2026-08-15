import AppKit
import SwiftUI

internal struct SpaceOnboardingStep: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        OnboardingSurface(step: .space, onBack: store.goBackInInitialOnboarding) {
            UpsertSpaceSidebarComposer(store: store, mode: .initial)
                .frame(maxWidth: 360)
        } preview: {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingPageHeader(
                    symbolName: "square.stack.3d.up",
                    title: String(localized: "Give everything its place"),
                    detail: String(localized: "Keep work, personal browsing, and projects separate so you can switch context without losing your place.")
                )

                Spacer(minLength: 28)

                OnboardingSpacePreview()
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, alignment: .center)

                Spacer(minLength: 28)

                Text("Start with one Space. Add more anytime as your workflow grows.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 430, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct OnboardingSpacePreview: View {
    private struct ExampleSpace: Identifiable {
        let name: String
        let detail: String
        let symbolName: String
        let isActive: Bool

        var id: String { name }
    }

    private let spaces = [
        ExampleSpace(
            name: String(localized: "Personal"),
            detail: String(localized: "Everyday browsing"),
            symbolName: "person.crop.circle",
            isActive: true
        ),
        ExampleSpace(
            name: String(localized: "Work"),
            detail: String(localized: "Projects and planning"),
            symbolName: "briefcase",
            isActive: false
        ),
        ExampleSpace(
            name: String(localized: "Research"),
            detail: String(localized: "Ideas worth returning to"),
            symbolName: "book.closed",
            isActive: false
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Spaces")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            ForEach(spaces) { space in
                HStack(spacing: 12) {
                    Image(systemName: space.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(space.isActive ? AppColor.accent : .secondary)
                        .frame(width: 30, height: 30)
                        .background(
                            space.isActive
                                ? AppColor.accent.opacity(0.14)
                                : InterfaceStyle.sidebarControlFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(space.name)
                            .font(.system(size: 13, weight: .semibold))

                        Text(space.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if space.isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(AppColor.accent)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 58)
                .background(
                    space.isActive
                        ? AppColor.accent.opacity(0.08)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.42),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            space.isActive
                                ? AppColor.accent.opacity(0.34)
                                : InterfaceStyle.surfaceBorder,
                            lineWidth: 1
                        )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    space.isActive
                        ? "\(space.name), \(space.detail), current Space"
                        : "\(space.name), \(space.detail)"
                )
            }
        }
        .padding(16)
        .background(
            Color(nsColor: .windowBackgroundColor).opacity(0.34),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(InterfaceStyle.surfaceBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Example Spaces")
    }
}
