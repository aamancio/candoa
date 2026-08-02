import AppKit
import SwiftUI

struct BrowserInterfaceView: View {
    @ObservedObject var store: BrowserStore
    @FocusState private var isAddressFocused: Bool
    @State private var addressText = ""
    @State private var isAddressOverlayPresented = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button(action: store.goBack) {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!store.canGoBack)
                    .help("Back")

                    Button(action: store.goForward) {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!store.canGoForward)
                    .help("Forward")

                    if store.activeTab?.isLoading == true {
                        Button(action: store.stopLoadingActiveTab) {
                            Image(systemName: "xmark")
                        }
                        .help("Stop")
                    } else {
                        Button(action: store.reloadActiveTab) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Reload")
                    }

                    Spacer()

                    Button {
                        store.openCommandPalette()
                    } label: {
                        Image(systemName: "command")
                    }
                    .help("Command Palette")

                    Button {
                        store.toggleSplitView()
                    } label: {
                        Image(systemName: store.isSplitViewDisplayed ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    }
                    .help(store.isSplitViewDisplayed ? "Close Split View" : "Open Split View")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                ProgressView(value: store.activeTab?.loadingProgress ?? 0)
                    .progressViewStyle(.linear)
                    .opacity(store.activeTab?.isLoading == true ? 1 : 0)
                    .frame(height: 2)
            }
            .background(.regularMaterial)

            if isAddressOverlayPresented {
                TextField(BrowserDefaults.addressPlaceholder, text: $addressText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .tint(CandoaColor.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(width: 560)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: Color(nsColor: .shadowColor).opacity(0.18), radius: 18, y: 8)
                    .focused($isAddressFocused)
                    .onSubmit {
                        store.navigateActiveTab(to: addressText)
                        closeAddressOverlay()
                    }
                    .onExitCommand {
                        closeAddressOverlay()
                    }
                    .padding(.top, 6)
                    .zIndex(2)
            }
        }
        .candoaButton(.chrome)
        .onAppear(perform: syncAddressText)
        .onChange(of: store.activeTabID) { _, _ in syncAddressText() }
        .onChange(of: store.activeTab?.url) { _, _ in syncAddressText() }
        .onChange(of: store.addressFocusRequestID) { _, _ in
            syncAddressText()
            isAddressOverlayPresented = true
            DispatchQueue.main.async {
                isAddressFocused = true
            }
        }
        .onChange(of: isAddressFocused) { _, focused in
            if !focused {
                isAddressOverlayPresented = false
            }
        }
    }

    private func syncAddressText() {
        addressText = store.activeTab?.url?.absoluteString ?? ""
    }

    private func closeAddressOverlay() {
        isAddressFocused = false
        isAddressOverlayPresented = false
    }
}
