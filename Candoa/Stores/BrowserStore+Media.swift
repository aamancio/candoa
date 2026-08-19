import Foundation
import SwiftUI

extension BrowserStore {
    var mediaControllerTab: BrowserTab? {
        guard let mediaControllerTabID else { return nil }
        return tabs.first { $0.id == mediaControllerTabID }
    }

    var mediaControllerState: TabMediaState? {
        guard let mediaControllerTabID else { return nil }
        return mediaStates[mediaControllerTabID]
    }

    var backgroundMediaControllerTab: BrowserTab? {
        guard let tab = mediaControllerTab, tab.id != activeTabID else { return nil }
        if displayedSplitTabIDs.contains(tab.id) { return nil }
        return tab
    }

    var backgroundMediaControllerState: TabMediaState? {
        guard let tabID = backgroundMediaControllerTab?.id else { return nil }
        return mediaStates[tabID]
    }

    var floatingMiniPlayerTab: BrowserTab? {
        guard isFloatingMiniPlayerEnabled else { return nil }
        guard let tab = backgroundMediaControllerTab, tab.id != dismissedMiniPlayerTabID else { return nil }
        guard mediaStates[tab.id]?.isMiniPlayerEligible == true,
              mediaStates[tab.id]?.isPlaying == true || retainedPausedMiniPlayerTabID == tab.id else {
            return nil
        }
        return tab
    }

    var floatingMiniPlayerState: TabMediaState? {
        guard let tabID = floatingMiniPlayerTab?.id else { return nil }
        return mediaStates[tabID]
    }

    func updateMediaState(tabID: UUID, state: TabMediaState) {
        guard tabs.contains(where: { $0.id == tabID }) else { return }
        var state = state
        if state.hasMedia, state.pageVideoFrame == nil {
            state.pageVideoFrame = mediaStates[tabID]?.pageVideoFrame
        }
        mediaStates[tabID] = state.hasMedia ? state : nil

        if state.isPlaying, state.isMiniPlayerEligible {
            if mediaControllerTabID != tabID {
                // Two pages playing at once (a muted hero video ticking away
                // in a background tab next to the one in the player) must
                // not trade the controller back and forth on every progress
                // report — each trade re-hosts the floating player and it
                // flickers between the two. A background page only takes
                // over from a controller that has stopped playing; the
                // page in front always does, since that is the person's
                // choice.
                let controllerStillPlaying = mediaControllerTabID.flatMap { mediaStates[$0] }?.isPlaying == true
                if controllerStillPlaying, !isDisplayed(tabID) { return }
                if let previousOwnerID = mediaControllerTabID {
                    webCoordinator.detachMiniPlayerWebView(for: previousOwnerID)
                }
                dismissedMiniPlayerTabID = nil
            }
            retainedPausedMiniPlayerTabID = nil
            mediaControllerTabID = tabID
        } else if mediaControllerTabID == tabID {
            if state.hasMedia, state.isMiniPlayerEligible, retainedPausedMiniPlayerTabID == tabID { return }
            // A pause that lands while the player is floating (the media
            // key, the page's own controls) keeps it up in paused mode —
            // only its close button, the media ending, or the media
            // disappearing dismisses. The player's own pause button takes
            // the retained path above instead.
            if state.hasMedia, state.isMiniPlayerEligible, webCoordinator.miniPlayerHostedTabID == tabID {
                retainedPausedMiniPlayerTabID = tabID
                return
            }
            mediaControllerTabID = nil
            dismissedMiniPlayerTabID = nil
            retainedPausedMiniPlayerTabID = nil
            webCoordinator.detachMiniPlayerWebView(for: tabID)
        }
    }

    func toggleMediaPlayback() { guard let mediaControllerTabID else { return }; webCoordinator.toggleMediaPlayback(tabID: mediaControllerTabID) }
    func toggleMiniPlayerPlayback() { guard let mediaControllerTabID else { return }; retainedPausedMiniPlayerTabID = mediaControllerTabID; webCoordinator.toggleMediaPlayback(tabID: mediaControllerTabID) }
    func toggleMediaMute() { guard let mediaControllerTabID else { return }; toggleMediaMute(tabID: mediaControllerTabID) }
    func toggleMediaMute(tabID: UUID) { webCoordinator.toggleMediaMute(tabID: tabID) }
    // Mute menu commands. mediaStates only holds tabs whose pages reported
    // media, so iterating it enumerates every candidate tab; unloaded or
    // hibernated tabs can't produce audio, so the DOM-level mute is enough.
    var canMuteActiveTab: Bool {
        guard let activeTabID else { return false }
        return mediaStates[activeTabID]?.hasMedia == true
    }

    var isActiveTabMuted: Bool {
        guard let activeTabID else { return false }
        return mediaStates[activeTabID]?.isMuted == true
    }

    func toggleActiveTabMute() { guard let activeTabID else { return }; toggleMediaMute(tabID: activeTabID) }

    var canMuteOtherTabs: Bool {
        mediaStates.contains { tabID, state in
            tabID != activeTabID && state.hasMedia && !state.isMuted
        }
    }

    func muteOtherTabs() {
        // The page script reports the resulting volumechange back, which
        // updates mediaStates and re-renders the menu — no manual
        // objectWillChange needed.
        for (tabID, state) in mediaStates where tabID != activeTabID && state.hasMedia {
            webCoordinator.setMediaMuted(true, tabID: tabID)
        }
    }

    func skipMediaTrack(forward: Bool) { guard let mediaControllerTabID else { return }; webCoordinator.skipMediaTrack(tabID: mediaControllerTabID, forward: forward) }
    func seekMedia(by seconds: Double) { guard let mediaControllerTabID else { return }; webCoordinator.seekMedia(tabID: mediaControllerTabID, by: seconds) }
    func seekMedia(to time: Double) { guard let mediaControllerTabID, time.isFinite else { return }; webCoordinator.seekMedia(tabID: mediaControllerTabID, to: max(0, time)) }

    func focusMediaTab() {
        guard let mediaControllerTabID else { return }
        dismissedMiniPlayerTabID = nil
        retainedPausedMiniPlayerTabID = nil
        switchTab(to: mediaControllerTabID)
    }

    func minimizeMiniPlayer() { hideMiniPlayer(pausesPlayback: false) }
    func dismissMiniPlayer() { hideMiniPlayer(pausesPlayback: true) }
    func consumeMiniPlayerSummon() { pendingMiniPlayerSummon = nil }

    /// Settings changed: a toggle turned off while the player floats hands
    /// the page back right away so it is not left stripped to its video.
    func syncFloatingMiniPlayerPreference() {
        let enabled = SettingsOption.bool(SettingsOption.floatingMiniPlayer, default: true)
        guard enabled != isFloatingMiniPlayerEnabled else { return }
        isFloatingMiniPlayerEnabled = enabled
        if !enabled, let hostedTabID = webCoordinator.miniPlayerHostedTabID {
            webCoordinator.detachMiniPlayerWebView(for: hostedTabID)
        }
    }

    /// The summon glide landed: the page styles down to the video at player
    /// size (the stage hand-off, see the coordinator).
    func miniPlayerSummonGlideDidEnd(tabID: UUID) {
        webCoordinator.finishMiniPlayerSummon(for: tabID)
    }

    /// Back to the floating player's tab. The page never lost its full
    /// layout; the player's presentation comes off and the switch lands in
    /// the frame that commits it — the page appears at full size at once,
    /// the way Arc's does, and the player is simply gone. No morph back onto
    /// the page: a player growing over a page reads as flicker.
    func beginMiniPlayerReturn(tabID: UUID, updatesAccessTime: Bool) {
        pendingMiniPlayerReturnTabID = tabID
        retainedPausedMiniPlayerTabID = tabID

        webCoordinator.prepareMiniPlayerReturn(for: tabID) { [weak self] in
            guard let self else { return }
            // Another switch landed meanwhile (it cleared the pending
            // return): the player floats on, so the page styles back down.
            guard self.pendingMiniPlayerReturnTabID == tabID else {
                self.webCoordinator.abandonMiniPlayerReturn(for: tabID)
                return
            }
            self.dismissedMiniPlayerTabID = nil
            self.retainedPausedMiniPlayerTabID = nil
            self.performSwitchTab(to: tabID, updatesAccessTime: updatesAccessTime)
        }
    }

    private func hideMiniPlayer(pausesPlayback: Bool) {
        guard let mediaControllerTabID else { return }
        if pausesPlayback { webCoordinator.pauseMediaPlayback(tabID: mediaControllerTabID) }
        dismissedMiniPlayerTabID = mediaControllerTabID
        retainedPausedMiniPlayerTabID = nil
        webCoordinator.detachMiniPlayerWebView(for: mediaControllerTabID)
    }

    private func isDisplayed(_ tabID: UUID) -> Bool {
        tabID == activeTabID || displayedSplitTabIDs.contains(tabID)
    }

    func handleActiveTabChange(from previousID: UUID?) {
        if activeTabID == dismissedMiniPlayerTabID { dismissedMiniPlayerTabID = nil }
        if let previousID, floatingMiniPlayerTab?.id == previousID {
            pendingMiniPlayerSummon = MiniPlayerSummonContext(pageVideoFrame: mediaStates[previousID]?.pageVideoFrame)
        } else {
            pendingMiniPlayerSummon = nil
        }
        if let previousID, !displayedSplitTabIDs.contains(previousID), tabs.contains(where: { $0.id == previousID }) {
            webCoordinator.refreshMediaState(tabID: previousID)
        }
        if let activeTabID { webCoordinator.refreshMediaState(tabID: activeTabID) }
        // Reader availability is established lazily for whichever tab is
        // frontmost; a finished page probes at most once.
        if let activeTabID { webCoordinator.probeReaderAvailabilityIfNeeded(for: activeTabID) }
    }
}
