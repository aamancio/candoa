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
                    .foregroundStyle(CandoaInterfaceStyle.sidebarText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering && !isInstalling ? CandoaInterfaceStyle.updateBannerFillHover : CandoaInterfaceStyle.updateBannerFill)
            )
            .overlay {
                Capsule(style: .continuous)
                    .stroke(CandoaInterfaceStyle.updateBannerStroke, lineWidth: 1)
            }
            .contentShape(Capsule(style: .continuous))
        }
        .candoaButton(.content)
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
                .candoaButton(.primary)
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
        .onChange(of: isInstalling) { installing in
            if installing {
                isUpdatePanelPresented = false
            }
        }
        .onDisappear {
            hoverPresentationTask?.cancel()
        }
    }
}
