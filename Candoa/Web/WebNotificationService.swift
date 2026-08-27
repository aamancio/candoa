import AppKit
import UserNotifications

/// Delivers pages' Notification-API notifications through Notification
/// Center and routes clicks back to the tab that posted them.
///
/// WKWebView exposes no Notification or Web Push support to third-party
/// browsers — `window.Notification` simply doesn't exist in pages — so
/// Candoa provides the API itself: `WebPageScripts.notificationShimScript`
/// implements it in the page and bridges here, where notifications become
/// real `UNUserNotificationCenter` deliveries. That makes this a
/// tab-lifetime feature by construction: a site can notify while it is
/// open in a tab, and background push (a service worker woken for a closed
/// site) stays impossible without WebKit's browser-entitlement push
/// daemon. Focus and Do Not Disturb come for free from the system.
@MainActor
final class WebNotificationService: NSObject {
    static let shared = WebNotificationService()

    private struct WeakStore {
        weak var window: NSWindow?
        weak var store: BrowserStore?
    }

    private var stores: [ObjectIdentifier: WeakStore] = [:]
    private var authorizationRequested = false
    /// Delivered-notification identifiers by tab and the page's own
    /// notification id, so a page calling `close()` can retract exactly the
    /// banner it posted.
    private var deliveredIdentifiers: [UUID: [String: String]] = [:]

    private static let isUITesting =
        ProcessInfo.processInfo.environment["CANDOA_UI_TESTING"] == "1"

    /// Claims the notification-center delegate at launch, before any stored
    /// notification click can arrive from a previous run.
    func activate() {
        guard !Self.isUITesting else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Every window registers its own store, mirroring
    /// `BrowserMenuController`: a notification click has to find its tab
    /// across all open windows, not just the key one.
    func register(window: NSWindow, store: BrowserStore) {
        stores[ObjectIdentifier(window)] = WeakStore(window: window, store: store)
    }

    /// The app-level authorization prompt appears the first time a site is
    /// allowed, not at launch — nobody should be asked about notifications
    /// before any site wants to send one.
    func requestAuthorizationIfNeeded() {
        guard !Self.isUITesting, !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    func show(
        pageNotificationID: String,
        title: String,
        body: String,
        tag: String,
        originKey: String,
        host: String,
        tabID: UUID
    ) {
        guard !Self.isUITesting else { return }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(200))
        content.subtitle = host
        content.body = String(body.prefix(500))
        content.threadIdentifier = originKey
        content.userInfo = [
            "candoaWebNotification": true,
            "tabID": tabID.uuidString,
            "pageNotificationID": pageNotificationID,
            "originKey": originKey
        ]

        // A tag replaces the origin's previous notification with the same
        // tag — the Notification API's coalescing — because same-identifier
        // requests replace each other in Notification Center.
        let identifier = tag.isEmpty
            ? "web-notification.\(tabID.uuidString).\(pageNotificationID)"
            : "web-notification.\(originKey).tag.\(tag.prefix(100))"
        deliveredIdentifiers[tabID, default: [:]][pageNotificationID] = identifier

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    func close(pageNotificationID: String, tabID: UUID) {
        guard let identifier = deliveredIdentifiers[tabID]?[pageNotificationID] else { return }
        deliveredIdentifiers[tabID]?.removeValue(forKey: pageNotificationID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func forgetTab(_ tabID: UUID) {
        deliveredIdentifiers[tabID] = nil
    }

    /// Focuses the tab a notification came from — window and Space included —
    /// and lets its page dispatch the click event. A tab closed since the
    /// notification fired falls back to reopening its site.
    private func routeClick(tabID: UUID, pageNotificationID: String, originKey: String) {
        stores = stores.filter { $0.value.window != nil && $0.value.store != nil }

        if let entry = stores.values.first(where: { entry in
            entry.store?.tabs.contains(where: { $0.id == tabID }) == true
        }), let window = entry.window, let store = entry.store {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            store.switchTab(to: tabID)
            store.webCoordinator.dispatchWebNotificationClick(
                pageNotificationID: pageNotificationID,
                tabID: tabID
            )
            return
        }

        // The tab is gone. Its origin key is scheme://host:port — reopen the
        // site in a regular window rather than dropping the click.
        guard
            let url = Self.originURL(fromOriginKey: originKey),
            let entry = stores.values.first(where: { $0.store?.isPrivate == false }),
            let window = entry.window,
            let store = entry.store
        else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        _ = store.newTab(url: url)
    }

    nonisolated static func originURL(fromOriginKey originKey: String) -> URL? {
        guard
            let url = URL(string: originKey),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host(), !host.isEmpty
        else { return nil }
        // The key spells default ports out; the reopened URL shouldn't.
        let port = url.port
        let isDefaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return URL(string: "\(scheme)://\(host)\(isDefaultPort || port == nil ? "" : ":\(port!)")/")
    }
}

extension WebNotificationService: UNUserNotificationCenterDelegate {
    /// Web notifications show even while Candoa is frontmost — the person
    /// may be in another tab, window, or Space than the page that posted.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let isWebNotification =
            notification.request.content.userInfo["candoaWebNotification"] as? Bool == true
        completionHandler(isWebNotification ? [.banner, .list] : [])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard
            response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            userInfo["candoaWebNotification"] as? Bool == true,
            let tabIDString = userInfo["tabID"] as? String,
            let tabID = UUID(uuidString: tabIDString),
            let pageNotificationID = userInfo["pageNotificationID"] as? String,
            let originKey = userInfo["originKey"] as? String
        else {
            completionHandler()
            return
        }
        // The system needs no result from routing; answering immediately
        // keeps the non-Sendable handler out of the main-actor hop.
        completionHandler()
        Task { @MainActor in
            self.routeClick(
                tabID: tabID,
                pageNotificationID: pageNotificationID,
                originKey: originKey
            )
        }
    }
}
