import AppKit
import Combine
import WebKit

/// Owns the app's one `WKWebExtensionController` and everything around it:
/// the installed-extension records, the loaded extension contexts, and the
/// per-window adapters that present Candoa's tabs and windows to extensions.
///
/// WebKit runs the extensions themselves — content scripts, background
/// service workers, `browser.*` APIs, storage — once a web view's
/// configuration carries the controller. This class only wires Candoa's world
/// into it: `register(window:store:)` announces windows, Combine
/// subscriptions diff each store's published tab state into
/// open/close/activate/change events, and the delegate answers the
/// controller's questions (open windows, new tabs, permission prompts).
///
/// Private windows are excluded entirely in v1, matching their
/// nothing-persists design.
@available(macOS 15.4, *)
@MainActor
final class WebExtensionManager: NSObject, ObservableObject {
    static let shared = WebExtensionManager()

    let controller: WKWebExtensionController

    @Published private(set) var installations: [WebExtensionInstallation]
    /// Extensions that failed to load this launch (missing bundle, manifest
    /// errors), so the settings pane can say why a row is inert.
    @Published private(set) var loadFailureDescriptions: [UUID: String] = [:]

    /// Bumped whenever an extension updates its action (badge, icon,
    /// enablement), so action surfaces re-render.
    @Published private(set) var actionRefreshToken = UUID()

    private var contextsByInstallationID: [UUID: WKWebExtensionContext] = [:]
    private var windowAdapters: [ObjectIdentifier: WebExtensionWindowAdapter] = [:]
    private var windowCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]
    /// Per-window anchor for WebKit's action-popup NSPopovers — the sidebar
    /// header's extensions button registers itself here.
    private let actionAnchors = NSMapTable<NSWindow, NSView>.weakToWeakObjects()

    private override init() {
        controller = WKWebExtensionController(configuration: .default())
        installations = WebExtensionRecords.load()
        super.init()
        controller.delegate = self
        Task { await loadEnabledExtensions() }
    }

    func icon(for installationID: UUID, size: CGFloat) -> NSImage? {
        contextsByInstallationID[installationID]?.webExtension.icon(for: CGSize(width: size, height: size))
    }

    func isLoaded(_ installationID: UUID) -> Bool {
        contextsByInstallationID[installationID] != nil
    }

    var hasLoadedExtensions: Bool {
        !contextsByInstallationID.isEmpty
    }

    func displayDescription(for installationID: UUID) -> String? {
        contextsByInstallationID[installationID]?.webExtension.displayDescription
    }

    /// What the extension can currently reach on the web, for the settings
    /// pane's plain-language permissions callout.
    enum WebsiteAccess {
        case allWebsites
        case websites([String])
        case none
    }

    func websiteAccess(for installationID: UUID) -> WebsiteAccess? {
        guard let context = contextsByInstallationID[installationID] else { return nil }
        let patterns = context.currentPermissionMatchPatterns
        if context.hasAccessToAllURLs || patterns.contains(where: { $0.matchesAllHosts }) {
            return .allWebsites
        }
        let hosts = Set(patterns.compactMap(\.host)).sorted()
        return hosts.isEmpty ? WebsiteAccess.none : .websites(hosts)
    }

    /// Whether any loaded extension may appear in the given browsing mode —
    /// private windows only surface extensions explicitly granted access.
    func hasLoadedExtensions(forPrivateBrowsing isPrivate: Bool) -> Bool {
        guard isPrivate else { return hasLoadedExtensions }
        return installations.contains {
            $0.allowsPrivateBrowsing && contextsByInstallationID[$0.id] != nil
        }
    }

    // MARK: - Toolbar actions

    struct ActionDescriptor: Identifiable {
        let id: UUID
        let label: String
        let badgeText: String
        let icon: NSImage?
        let isEnabled: Bool
    }

    /// The loaded extensions' actions against the focused window's active
    /// tab, in installation order. In a private window, only extensions
    /// granted private-browsing access are listed.
    func actionDescriptors() -> [ActionDescriptor] {
        let isPrivateWindow = focusedWindowAdapter?.store?.isPrivate ?? false
        let tabAdapter = focusedActiveTabAdapter
        return installations.compactMap { installation in
            guard !isPrivateWindow || installation.allowsPrivateBrowsing else { return nil }
            guard
                let context = contextsByInstallationID[installation.id],
                let action = context.action(for: tabAdapter)
            else {
                return nil
            }
            let label = action.label.isEmpty ? installation.displayName : action.label
            return ActionDescriptor(
                id: installation.id,
                label: label,
                badgeText: action.badgeText,
                icon: action.icon(for: CGSize(width: 32, height: 32)),
                isEnabled: action.isEnabled
            )
        }
    }

    /// Performs an extension's toolbar action for the active tab: WebKit
    /// either asks us to present the action's popup (delegate below) or
    /// fires `action.onClicked` in the extension's background script.
    func performAction(for installationID: UUID) {
        guard let context = contextsByInstallationID[installationID] else { return }
        context.performAction(for: focusedActiveTabAdapter)
    }

    func registerActionAnchor(_ view: NSView, for window: NSWindow) {
        actionAnchors.setObject(view, forKey: window)
    }

    private var focusedActiveTabAdapter: WebExtensionTabAdapter? {
        guard
            let windowAdapter = focusedWindowAdapter,
            let activeTabID = windowAdapter.store?.activeTabID
        else {
            return nil
        }
        return windowAdapter.adapter(for: activeTabID)
    }

    // MARK: - Install / remove / enable

    enum InstallOutcome {
        case installed(WebExtensionInstallation)
        case declined
    }

    /// Stages the picked folder or archive, confirms the extension's
    /// requested permissions with the person, and loads it. The staged copy
    /// is deleted again whenever anything short-circuits.
    func install(from sourceURL: URL) async throws -> InstallOutcome {
        let installationID = UUID()
        let destination = WebExtensionRecords.directoryURL(for: installationID)
        let manifestRoot = try await Task.detached(priority: .userInitiated) {
            try WebExtensionInstaller.stage(sourceURL, to: destination)
        }.value

        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: manifestRoot)
            guard confirmInstall(of: webExtension) else {
                try? FileManager.default.removeItem(at: destination)
                return .declined
            }

            let installation = WebExtensionInstallation(
                id: installationID,
                displayName: webExtension.displayName ?? manifestRoot.lastPathComponent,
                version: webExtension.version ?? "",
                isEnabled: true,
                installedAt: Date()
            )
            try loadContext(for: webExtension, installation: installation)
            installations.append(installation)
            WebExtensionRecords.save(installations)
            return .installed(installation)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func setAllowsPrivateBrowsing(_ allowed: Bool, for installationID: UUID) {
        guard let index = installations.firstIndex(where: { $0.id == installationID }) else { return }
        guard installations[index].allowsPrivateBrowsing != allowed else { return }
        installations[index].allowsPrivateBrowsing = allowed
        WebExtensionRecords.save(installations)
        contextsByInstallationID[installationID]?.hasAccessToPrivateData = allowed
        // Private-window surfaces (sidebar button, menu) key off this.
        actionRefreshToken = UUID()
    }

    func setEnabled(_ isEnabled: Bool, for installationID: UUID) {
        guard let index = installations.firstIndex(where: { $0.id == installationID }) else { return }
        guard installations[index].isEnabled != isEnabled else { return }
        installations[index].isEnabled = isEnabled
        WebExtensionRecords.save(installations)

        if isEnabled {
            let installation = installations[index]
            Task { await loadPersistedExtension(installation) }
        } else if let context = contextsByInstallationID.removeValue(forKey: installationID) {
            try? controller.unload(context)
        }
    }

    func remove(_ installationID: UUID) {
        // Order matters: the context must still be loaded for its stored data
        // (browser.storage, and so on) to be discoverable and removable.
        if let context = contextsByInstallationID[installationID] {
            let dataTypes = WKWebExtensionController.allExtensionDataTypes
            controller.fetchDataRecord(ofTypes: dataTypes, for: context) { [weak self] record in
                guard let self, let record else { return }
                self.controller.removeData(ofTypes: dataTypes, from: [record]) {}
            }
            try? controller.unload(context)
            contextsByInstallationID.removeValue(forKey: installationID)
        }
        try? FileManager.default.removeItem(at: WebExtensionRecords.directoryURL(for: installationID))
        installations.removeAll { $0.id == installationID }
        loadFailureDescriptions.removeValue(forKey: installationID)
        WebExtensionRecords.save(installations)
    }

    private func loadEnabledExtensions() async {
        for installation in installations where installation.isEnabled {
            await loadPersistedExtension(installation)
        }
    }

    private func loadPersistedExtension(_ installation: WebExtensionInstallation) async {
        guard contextsByInstallationID[installation.id] == nil else { return }
        let directory = WebExtensionRecords.directoryURL(for: installation.id)
        guard let manifestRoot = WebExtensionInstaller.manifestRoot(in: directory) else {
            loadFailureDescriptions[installation.id] = String(
                localized: "The extension's files are missing."
            )
            return
        }
        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: manifestRoot)
            try loadContext(for: webExtension, installation: installation)
            loadFailureDescriptions.removeValue(forKey: installation.id)
        } catch {
            loadFailureDescriptions[installation.id] = error.localizedDescription
        }
    }

    /// v1 grants everything the manifest requests up front (the person just
    /// reviewed the list in the install prompt); optional permissions
    /// requested at runtime still go through the delegate prompts below.
    private func loadContext(
        for webExtension: WKWebExtension,
        installation: WebExtensionInstallation
    ) throws {
        let context = WKWebExtensionContext(for: webExtension)
        // Stable across launches, so the extension's storage survives.
        context.uniqueIdentifier = installation.id.uuidString
        context.isInspectable = WebInspectorConfiguration.isEnabled
        context.hasAccessToPrivateData = installation.allowsPrivateBrowsing
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission, expirationDate: nil)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern, expirationDate: nil)
        }
        try controller.load(context)
        contextsByInstallationID[installation.id] = context
    }

    private func confirmInstall(of webExtension: WKWebExtension) -> Bool {
        let alert = NSAlert()
        let name = webExtension.displayName ?? String(localized: "This extension")
        alert.messageText = String(localized: "Install “\(name)”?")
        var details: [String] = []
        let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
        if !permissions.isEmpty {
            details.append(String(localized: "Permissions: \(permissions.joined(separator: ", "))"))
        }
        let hosts = webExtension.requestedPermissionMatchPatterns.map(\.string).sorted()
        if !hosts.isEmpty {
            details.append(String(localized: "Websites: \(hosts.joined(separator: ", "))"))
        }
        alert.informativeText = details.isEmpty
            ? String(localized: "It requests no special permissions.")
            : details.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Window and tab bookkeeping

    /// Idempotent — the window configurator calls this on every SwiftUI
    /// update pass, exactly like the menu controller's registration.
    /// Private windows register too: their adapters report `isPrivate`, and
    /// only contexts granted `hasAccessToPrivateData` ever see them.
    func register(window: NSWindow, store: BrowserStore) {
        let key = ObjectIdentifier(window)
        if let existing = windowAdapters[key], existing.store === store { return }
        unregister(windowKey: key)

        let adapter = WebExtensionWindowAdapter(store: store, window: window)
        windowAdapters[key] = adapter
        adapter.knownTabs = Dictionary(
            uniqueKeysWithValues: store.tabs.map { ($0.id, WebExtensionTabSnapshot($0)) }
        )
        controller.didOpenWindow(adapter)

        var cancellables = Set<AnyCancellable>()
        // @Published emits on willSet; receive(on:) defers each event until
        // after the store mutation lands, so adapters queried by the
        // controller mid-event see the new state.
        store.$tabs
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak adapter] tabs in
                guard let self, let adapter else { return }
                self.reconcileTabs(tabs, in: adapter)
            }
            .store(in: &cancellables)
        store.$activeTabID
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak adapter] activeTabID in
                guard let self, let adapter else { return }
                self.reconcileActiveTab(activeTabID, in: adapter)
            }
            .store(in: &cancellables)
        windowCancellables[key] = cancellables

        let center = NotificationCenter.default
        windowObservers[key] = [
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let adapter = self.windowAdapters[key] else { return }
                    self.controller.didFocusWindow(adapter)
                }
            },
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.unregister(windowKey: key)
                }
            }
        ]
    }

    private func unregister(windowKey key: ObjectIdentifier) {
        windowCancellables.removeValue(forKey: key)
        if let observers = windowObservers.removeValue(forKey: key) {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
        if let adapter = windowAdapters.removeValue(forKey: key) {
            controller.didCloseWindow(adapter)
        }
    }

    private func reconcileTabs(_ tabs: [BrowserTab], in adapter: WebExtensionWindowAdapter) {
        let currentByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })

        for closedID in adapter.knownTabs.keys where currentByID[closedID] == nil {
            adapter.knownTabs.removeValue(forKey: closedID)
            let tabAdapter = adapter.adapter(for: closedID)
            adapter.removeAdapter(for: closedID)
            controller.didCloseTab(tabAdapter, windowIsClosing: false)
        }

        for tab in tabs {
            if let previous = adapter.knownTabs[tab.id] {
                let changed = WebExtensionTabSnapshot(tab).changedProperties(since: previous)
                if !changed.isEmpty {
                    controller.didChangeTabProperties(changed, for: adapter.adapter(for: tab.id))
                }
            } else {
                controller.didOpenTab(adapter.adapter(for: tab.id))
            }
            adapter.knownTabs[tab.id] = WebExtensionTabSnapshot(tab)
        }
    }

    private func reconcileActiveTab(_ activeTabID: UUID?, in adapter: WebExtensionWindowAdapter) {
        guard adapter.knownActiveTabID != activeTabID else { return }
        let previous = adapter.knownActiveTabID.map { adapter.adapter(for: $0) }
        adapter.knownActiveTabID = activeTabID
        guard let activeTabID else { return }
        controller.didActivateTab(adapter.adapter(for: activeTabID), previousActiveTab: previous)
    }

    private var orderedWindowAdapters: [WebExtensionWindowAdapter] {
        var seen = Set<ObjectIdentifier>()
        var ordered: [WebExtensionWindowAdapter] = []
        for window in NSApp.orderedWindows {
            let key = ObjectIdentifier(window)
            if let adapter = windowAdapters[key], seen.insert(key).inserted {
                ordered.append(adapter)
            }
        }
        // Miniaturized windows leave orderedWindows but still hold tabs.
        for (key, adapter) in windowAdapters where seen.insert(key).inserted {
            ordered.append(adapter)
        }
        return ordered
    }

    private var focusedWindowAdapter: WebExtensionWindowAdapter? {
        if let key = NSApp.keyWindow, let adapter = windowAdapters[ObjectIdentifier(key)] {
            return adapter
        }
        return orderedWindowAdapters.first
    }
}

// MARK: - WKWebExtensionControllerDelegate

@available(macOS 15.4, *)
extension WebExtensionManager: WKWebExtensionControllerDelegate {
    /// Belt and suspenders on top of WebKit's own gating: a context without
    /// private-data access is never even told private windows exist.
    private func adapters(
        _ adapters: [WebExtensionWindowAdapter],
        visibleTo context: WKWebExtensionContext
    ) -> [WebExtensionWindowAdapter] {
        guard !context.hasAccessToPrivateData else { return adapters }
        return adapters.filter { !($0.store?.isPrivate ?? false) }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        adapters(orderedWindowAdapters, visibleTo: extensionContext)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        adapters(
            [focusedWindowAdapter].compactMap { $0 } + orderedWindowAdapters,
            visibleTo: extensionContext
        ).first
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let windowAdapter = (configuration.window as? WebExtensionWindowAdapter)
            ?? adapters(
                [focusedWindowAdapter].compactMap { $0 } + orderedWindowAdapters,
                visibleTo: extensionContext
            ).first
        guard let windowAdapter, let store = windowAdapter.store else {
            completionHandler(nil, WKWebExtension.Error(.unknown))
            return
        }
        let tabID: UUID
        if let url = configuration.url {
            tabID = store.newTab(url: url).id
        } else {
            // An extension asking for a URL-less tab gets Candoa's empty tab.
            // newEmptyTab always activates it; a rarely-hit mismatch with
            // shouldBeActive == false is acceptable over duplicating it.
            store.newEmptyTab()
            guard let newTabID = store.activeTabID else {
                completionHandler(nil, WKWebExtension.Error(.unknown))
                return
            }
            tabID = newTabID
        }
        // Announce the tab now and seed its snapshot; the deferred $tabs
        // reconcile then sees it as known and won't re-announce.
        let tabAdapter = windowAdapter.adapter(for: tabID)
        if let stored = store.tab(tabID) {
            windowAdapter.knownTabs[tabID] = WebExtensionTabSnapshot(stored)
        }
        controller.didOpenTab(tabAdapter)
        if configuration.shouldBeActive {
            store.switchTab(to: tabID)
        }
        completionHandler(tabAdapter, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let granted = promptForAccess(
            context: extensionContext,
            requestDescriptions: permissions.map(\.rawValue).sorted()
        )
        completionHandler(granted ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        let granted = promptForAccess(
            context: extensionContext,
            requestDescriptions: urls.map(\.absoluteString).sorted()
        )
        completionHandler(granted ? urls : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let granted = promptForAccess(
            context: extensionContext,
            requestDescriptions: matchPatterns.map(\.string).sorted()
        )
        completionHandler(granted ? matchPatterns : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover else {
            completionHandler(nil)
            return
        }
        let window = NSApp.keyWindow
        if let window,
           let anchor = actionAnchors.object(forKey: window),
           anchor.window === window {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
            completionHandler(nil)
        } else if let contentView = window?.contentView {
            // No extensions button on screen (sidebar hidden): fall back to
            // the window's top edge so the popup still appears.
            let anchorRect = NSRect(x: contentView.bounds.midX, y: contentView.bounds.maxY - 1, width: 1, height: 1)
            popover.show(relativeTo: anchorRect, of: contentView, preferredEdge: .minY)
            completionHandler(nil)
        } else {
            completionHandler(WKWebExtension.Error(.unknown))
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        actionRefreshToken = UUID()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard
            let url = extensionContext.optionsPageURL,
            let store = focusedWindowAdapter?.store
        else {
            completionHandler(WKWebExtension.Error(.unknown))
            return
        }
        let tab = store.newTab(url: url)
        store.switchTab(to: tab.id)
        completionHandler(nil)
    }

    /// Candoa has no native-messaging host registry; answer cleanly instead
    /// of leaving `runtime.sendNativeMessage` hanging.
    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        replyHandler(nil, NSError(
            domain: "app.candoa.browser.WebExtensions",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    localized: "No native messaging host is available."
                )
            ]
        ))
    }

    private func promptForAccess(
        context: WKWebExtensionContext,
        requestDescriptions: [String]
    ) -> Bool {
        let alert = NSAlert()
        let name = context.webExtension.displayName ?? String(localized: "This extension")
        alert.messageText = String(localized: "“\(name)” wants additional access.")
        alert.informativeText = requestDescriptions.joined(separator: "\n")
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
