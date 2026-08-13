import Foundation

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

    func beginMiniPlayerReturn(tabID: UUID, updatesAccessTime: Bool) {
        pendingMiniPlayerReturnTabID = tabID
        retainedPausedMiniPlayerTabID = tabID
        let targetFrame = mediaStates[tabID]?.pageVideoFrame
        let activeTabIDAtBegin = activeTabID

        webCoordinator.prepareMiniPlayerReturn(for: tabID) { [weak self] snapshot in
            guard let self, self.activeTabID == activeTabIDAtBegin, self.pendingMiniPlayerReturnTabID == tabID else { return }
            guard self.floatingMiniPlayerTab?.id == tabID, self.miniPlayerReturn == nil else {
                self.performSwitchTab(to: tabID, updatesAccessTime: updatesAccessTime)
                return
            }
            self.miniPlayerReturn = MiniPlayerReturnContext(tabID: tabID, updatesAccessTime: updatesAccessTime, snapshot: snapshot, targetFrame: targetFrame)
        }
    }

    func finishMiniPlayerReturn() {
        guard let returning = miniPlayerReturn else { return }
        dismissedMiniPlayerTabID = nil
        retainedPausedMiniPlayerTabID = nil
        performSwitchTab(to: returning.tabID, updatesAccessTime: returning.updatesAccessTime)
        miniPlayerReturn = nil
    }

    private func hideMiniPlayer(pausesPlayback: Bool) {
        guard let mediaControllerTabID else { return }
        if pausesPlayback { webCoordinator.pauseMediaPlayback(tabID: mediaControllerTabID) }
        dismissedMiniPlayerTabID = mediaControllerTabID
        retainedPausedMiniPlayerTabID = nil
        webCoordinator.detachMiniPlayerWebView(for: mediaControllerTabID)
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
