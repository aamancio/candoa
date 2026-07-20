import SwiftUI

internal struct AppUpdateBanner: View {
    let update: AppUpdate
    let automaticUpdatesEnabled: Binding<Bool>
    let action: () -> Void

    @State private var isHovering = false
    @State private var isUpdatePanelPresented = false
    @State private var hoverPresentationTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Text("New Candoa Version Available")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CandoaInterfaceStyle.sidebarText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(isHovering ? CandoaInterfaceStyle.updateBannerFillHover : CandoaInterfaceStyle.updateBannerFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(CandoaInterfaceStyle.updateBannerStroke, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            hoverPresentationTask?.cancel()

            guard hovering, !isUpdatePanelPresented else { return }
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
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(14)
            .frame(width: 280)
        }
        .help("Candoa \(update.version) is available")
        .animation(.easeOut(duration: 0.10), value: isHovering)
        .onDisappear {
            hoverPresentationTask?.cancel()
        }
    }
}
