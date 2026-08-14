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

    private var contextsByInstallationID: [UUID: WKWebExtensionContext] = [:]
    private var windowAdapters: [ObjectIdentifier: WebExtensionWindowAdapter] = [:]
    private var windowCancellables: [ObjectIdentifier: Set<AnyCancellable>] = [:]
    private var windowObservers: [ObjectIdentifier: [any NSObjectProtocol]] = [:]

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
    func register(window: NSWindow, store: BrowserStore) {
        guard !store.isPrivate else { return }
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
    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        orderedWindowAdapters
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        focusedWindowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let windowAdapter = (configuration.window as? WebExtensionWindowAdapter) ?? focusedWindowAdapter
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
