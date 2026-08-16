import AppKit
import Foundation
import WebKit

/// Off-screen preview warm-up for the tab switcher.
///
/// A tab that has never been displayed this run — restored lazily at launch,
/// opened in the background, synced in — has no live web view, no wake
/// snapshot, and (until this run persists one) nothing on disk, so its
/// switcher card falls back to favicon + title. Loading such a tab once in a
/// throwaway web view produces a real thumbnail.
///
/// The throwaway view is hosted in an invisible window (see
/// `PreviewWarmupJob.makeHostWindow`) rather than left unhosted: WebKit
/// renders an off-window `WKWebView` for `takeSnapshot`, but reports the page
/// as *hidden* (`document.visibilityState`), and single-page apps such as
/// YouTube gate their whole shell on visibility — the snapshot would show
/// only their loading skeleton, however long the load is left to settle. A
/// transparent, click-through window ordered below the desktop keeps the page
/// visible as far as WebKit is concerned without ever being seen.
///
/// The throwaway view deliberately is *not* the tab's web view: it carries no
/// navigation-history side effects, no extension controller (extensions must
/// not see a phantom tab), no message handlers, and is torn down as soon as
/// the capture lands — so a 40-tab session never fans out 40 WebContent
/// processes. At most `warmupConcurrency` loads run at once, and warm-up is
/// skipped entirely in private windows, under Low Power Mode, and in UI-test
/// runs.
extension WebViewCoordinator {
    func warmUpPreview(for tab: BrowserTab) {
        guard
            !isPrivate,
            !BrowserStore.isUITesting || Self.uiTestingWarmsUpPreviews,
            !ProcessInfo.processInfo.isLowPowerModeEnabled,
            let url = tab.url,
            Self.isWarmable(url),
            !tab.isWelcomePage,
            webViews[tab.id] == nil,
            !previewWarmupAttemptedTabIDs.contains(tab.id),
            previewWarmupJobs[tab.id] == nil,
            !previewWarmupQueue.contains(where: { $0.id == tab.id })
        else { return }

        previewWarmupQueue.append(tab)
        fillPreviewWarmupSlots()
    }

    /// UI-test runs keep warm-up off by default (no stray network, no timing
    /// noise); the switcher-preview test opts in and the job then serves the
    /// same fixture HTML the coordinator's own fixture intercept does.
    static var uiTestingWarmsUpPreviews: Bool {
        BrowserStore.isUITesting
            && ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PREVIEW_WARMUP"] == "1"
    }

    /// Only http(s) pages are worth (and safe) loading unseen: internal
    /// pages have their own rendering, and other schemes may have side effects.
    nonisolated static func isWarmable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    func cancelPreviewWarmup(for tabID: UUID) {
        previewWarmupQueue.removeAll { $0.id == tabID }
        previewWarmupJobs[tabID]?.cancel()
    }

    /// Starts queued loads until every warm-up slot is busy. Serial loading
    /// made a five-tab switcher fill in one card at a time over ~30s; a few
    /// in flight together get the whole row in one page-load's worth of time.
    private func fillPreviewWarmupSlots() {
        while previewWarmupJobs.count < TabSwitcherConfiguration.warmupConcurrency,
              !previewWarmupQueue.isEmpty {
            let tab = previewWarmupQueue.removeFirst()
            // The tab may have gone live or been closed while it waited.
            guard
                webViews[tab.id] == nil,
                store?.tabs.contains(where: { $0.id == tab.id }) == true,
                let url = tab.url
            else { continue }

            previewWarmupAttemptedTabIDs.insert(tab.id)
            let job = PreviewWarmupJob(
                tabID: tab.id,
                url: url,
                webView: makePreviewWarmupWebView(for: tab)
            ) { [weak self] image in
                guard let self else { return }
                self.previewWarmupJobs[tab.id] = nil
                if let image, self.webViews[tab.id] == nil {
                    self.store?.didCaptureTabSnapshot(image, for: tab.id)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + TabSwitcherConfiguration.warmupSpacing) { [weak self] in
                    self?.fillPreviewWarmupSlots()
                }
            }
            previewWarmupJobs[tab.id] = job
            job.start()
        }
    }

    /// A minimal sibling of `makeWebView(for:)`: same data store (so signed-in
    /// pages render as the person sees them), same UA and content mode, same
    /// tracking-protection rules and appearance — but nothing that would make
    /// the view observable as a tab.
    private func makePreviewWarmupWebView(for tab: BrowserTab) -> WKWebView {
        let dataStoreID = store?.dataStoreID(for: tab.spaceID) ?? tab.spaceID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = Self.sharedDataStore(forIdentifier: dataStoreID)
        configuration.applicationNameForUserAgent = Self.browserUserAgentApplicationName
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .desktop
        // Nothing should start playing in a view nobody can see.
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        if let contentRuleList, strictTrackingProtectionEnabled {
            configuration.userContentController.add(contentRuleList)
        }
        WebKitFeatureFlags.apply(to: configuration.preferences)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: TabSwitcherConfiguration.warmupViewportSize),
            configuration: configuration
        )
        applyWebsiteAppearance(to: webView)
        return webView
    }
}

/// One throwaway load: navigate, wait for the main frame to finish, let it
/// settle and go network-quiet, capture at switcher width, hand back the
/// image (or nil), release the web view. Owns its web view and its invisible
/// host window for the job's lifetime only.
@MainActor
final class PreviewWarmupJob: NSObject, WKNavigationDelegate {
    let tabID: UUID
    private let url: URL
    private var webView: WKWebView?
    private var hostWindow: NSWindow?
    private var completion: ((NSImage?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var settleScheduled = false
    private var quietWaitStartedAt: Date?
    private var lastResourceCount: Int?

    init(tabID: UUID, url: URL, webView: WKWebView, completion: @escaping (NSImage?) -> Void) {
        self.tabID = tabID
        self.url = url
        self.webView = webView
        self.completion = completion
        super.init()
    }

    func start() {
        guard let webView else { return }
        webView.navigationDelegate = self
        hostWindow = Self.makeHostWindow(hosting: webView)

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(with: nil)
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + TabSwitcherConfiguration.warmupLoadTimeout, execute: timeout)

        if BrowserStore.isUITesting,
           url.host == "fixture.candoa.test",
           let fixtureHTML = ProcessInfo.processInfo.environment["CANDOA_UI_TESTING_PAGE_HTML"] {
            webView.loadHTMLString(fixtureHTML, baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func finish(with image: NSImage?) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        hostWindow?.orderOut(nil)
        hostWindow = nil
        completion(image)
    }

    /// A window WebKit counts as visible and nobody can perceive: fully
    /// transparent, click-through, below the desktop picture, absent from the
    /// Window menu, Mission Control and ⌘-cycling. Verified by spike
    /// (2026-08-15): an unhosted view or one in an off-screen window yields
    /// `document.hidden == true`; this host yields `visible`, and pages that
    /// were stuck on their skeleton render fully.
    private static func makeHostWindow(hosting webView: WKWebView) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: webView.bounds.size),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary, .canJoinAllSpaces]
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.contentView = webView
        window.orderFrontRegardless()
        return window
    }

    /// Poll the page's resource count until it holds still for one quiet
    /// period (or the cap runs out), then capture. Runs in page JS, so a
    /// page that refuses evaluation simply captures now.
    private func waitForNetworkQuietThenCapture() {
        guard let webView, completion != nil else { return }
        let startedAt = quietWaitStartedAt ?? Date()
        quietWaitStartedAt = startedAt
        if Date().timeIntervalSince(startedAt) >= TabSwitcherConfiguration.warmupQuietWaitCap {
            capture()
            return
        }
        webView.evaluateJavaScript("performance.getEntriesByType('resource').length") { [weak self] result, _ in
            guard let self, self.completion != nil else { return }
            let count = (result as? NSNumber)?.intValue
            defer { lastResourceCount = count }
            guard let count, count != lastResourceCount else {
                capture()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + TabSwitcherConfiguration.warmupQuietPeriod) { [weak self] in
                self?.waitForNetworkQuietThenCapture()
            }
        }
    }

    private func capture() {
        guard let webView, completion != nil else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(value: Double(TabSwitcherConfiguration.snapshotWidth))
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            self?.finish(with: image)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page can finish more than once (client redirects, iframes'
        // main-frame reloads); the first finish owns the settle-and-capture.
        guard !settleScheduled else { return }
        settleScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + TabSwitcherConfiguration.warmupSettleDelay) { [weak self] in
            self?.waitForNetworkQuietThenCapture()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Follow redirects and in-page navigations, but never leave the web:
        // custom-scheme handoffs (mailto:, app links) would open other apps
        // from a page nobody clicked.
        guard let target = navigationAction.request.url, WebViewCoordinator.isWarmable(target) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // A response that would download is not a page: bail rather than
        // silently drop a file into Downloads.
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            finish(with: nil)
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(with: nil)
    }
}
