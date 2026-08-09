import AppKit
import Foundation
import SwiftUI

extension BrowserStore {
    func focusAddressBar() {
        guard !isInitialOnboardingBlockingBrowsing else { return }

        if isCommandPalettePresented {
            dismissCommandPalette()
            return
        }

        let activeURL = activeTab?.url
        commandPaletteInitialText = activeURL?.absoluteString ?? ""
        commandPaletteResumeQuery = activeURL.flatMap(navigationService.searchQuery(from:)) ?? ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = true
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false
        presentCommandPalette()
        addressFocusRequestID = UUID()
    }

    func focusSidebarAddressBar() {
        guard !isInitialOnboardingBlockingBrowsing else { return }

        if isCommandPalettePresented {
            dismissCommandPalette()
            return
        }

        let activeURL = activeTab?.url
        commandPaletteInitialText = activeURL?.absoluteString ?? ""
        commandPaletteResumeQuery = activeURL.flatMap(navigationService.searchQuery(from:)) ?? ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = true
        commandPaletteWasOpenedFromSidebarAddress = true
        commandPaletteOpensNewTab = false
        presentCommandPalette()
        addressFocusRequestID = UUID()
    }

    func setDeveloperMode(_ isEnabled: Bool, for url: URL) {
        DeveloperModeConfiguration.setEnabled(isEnabled, for: url)
    }

    func setSitePermission(
        _ decision: SitePermissionDecision,
        for permission: SitePermission,
        url: URL
    ) {
        SitePermissionConfiguration.setDecision(decision, for: permission, url: url)
    }

    func resetSitePermissions(for url: URL) {
        SitePermissionConfiguration.resetDecisions(for: url)
    }

    func siteSecuritySummary(for tabID: UUID?) -> SiteSecuritySummary? {
        guard let tabID else { return nil }
        return webCoordinator.siteSecuritySummary(forTabID: tabID)
    }

    func openCommandPalette() {
        guard !isInitialOnboardingBlockingBrowsing else { return }

        commandPaletteInitialText = ""
        commandPaletteResumeQuery = ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false
        presentCommandPalette()
    }

    func openNewTabCommandPalette() {
        guard !isInitialOnboardingBlockingBrowsing else { return }

        commandPaletteInitialText = ""
        commandPaletteResumeQuery = ""
        commandPaletteSessionID = UUID()
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = true
        presentCommandPalette()
    }

    /// Presentation animates; dismissal deliberately does not. An animated
    /// removal keeps the palette in the hierarchy for the transition's
    /// duration, and a committed command's web view swap landing in that
    /// window interrupts the transition — stranding an invisible palette
    /// that swallows every mouse click until ⌘T is pressed again.
    func presentCommandPalette() {
        guard !isCommandPalettePresented else { return }

        withAnimation(.easeOut(duration: 0.14)) {
            isCommandPalettePresented = true
        }
    }

    func dismissCommandPalette() {
        isCommandPalettePresented = false
        commandPalettePrefersCurrentTabNavigation = false
        commandPaletteWasOpenedFromSidebarAddress = false
        commandPaletteOpensNewTab = false

        // The palette's TextField unmounts while the window's field editor is
        // still bound to it. Without an explicit hand-back the orphaned field
        // editor stays first responder and the window drops mouse events.
        if let window = NSApp.keyWindow {
            window.endEditing(for: nil)
            window.makeFirstResponder(nil)
        }

        // Hand the page keyboard focus once the palette's TextField has actually
        // unmounted — claiming it here would be undone by that unmount.
        DispatchQueue.main.async { [weak self] in
            self?.webCoordinator.focusActiveWebViewIfIdle()
        }
    }

    /// Arc-style ⌘T: no tab exists yet — the sidebar's New Tab button takes
    /// the selection highlight while the palette is open, and the real tab is
    /// only created when a result is picked.
    var isNewTabPaletteActive: Bool {
        isCommandPalettePresented && commandPaletteOpensNewTab
    }

    func consumeCommandPaletteNewTabIntent() -> Bool {
        let opensNewTab = commandPaletteOpensNewTab
        commandPaletteOpensNewTab = false
        return opensNewTab
    }
}
