import SwiftUI

internal struct AppUpdateBanner: View {
    let update: AppUpdate
    let isInstalling: Bool
    let automaticUpdatesEnabled: Binding<Bool>
    let action: () -> Void

    @State private var isHovering = false
    @State private var isUpdatePanelPresented = false
    @State private var hoverPresentationTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isInstalling {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                Text(isInstalling ? "Installing Update…" : "Update Available")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(InterfaceStyle.sidebarText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            // Same as the What's New pill: the tint is nearly transparent, so
            // the material underneath is what lifts it off the tab list.
            .background(.regularMaterial, in: Capsule(style: .continuous))
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering && !isInstalling ? InterfaceStyle.updateBannerFillHover : InterfaceStyle.updateBannerFill)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(InterfaceStyle.updateBannerStroke, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonTreatment(.content)
        .disabled(isInstalling)
        .accessibilityIdentifier(isInstalling ? "sidebar-update-banner-installing" : "sidebar-update-banner")
        .onHover { hovering in
            isHovering = hovering
            hoverPresentationTask?.cancel()

            guard hovering, !isUpdatePanelPresented, !isInstalling else { return }
            hoverPresentationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, isHovering else { return }
                isUpdatePanelPresented = true
            }
        }
        .popover(isPresented: $isUpdatePanelPresented, arrowEdge: .bottom) {
            VStack(spacing: 10) {
                Text("New Candoa Version Available")
                    .font(.headline)

                Divider()

                Toggle(
                    "Automatic Updates",
                    isOn: automaticUpdatesEnabled
                )

                Button {
                    isUpdatePanelPresented = false
                    action()
                } label: {
                    Text("Restart and Update")
                        .frame(maxWidth: .infinity)
                }
                .buttonTreatment(.primary)
                .controlSize(.large)
            }
            .padding(14)
            .frame(width: 280)
        }
        .help(
            isInstalling
                ? "Candoa \(update.version) is installing and will relaunch shortly"
                : "Candoa \(update.version) is available"
        )
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .onChange(of: isInstalling) { _, installing in
            if installing {
                isUpdatePanelPresented = false
            }
        }
        .onDisappear {
            hoverPresentationTask?.cancel()
        }
    }
}
