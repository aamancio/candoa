import Foundation
import WebKit

/// Web Inspector control for the Develop menu, built on WebKit's private
/// `_WKInspector` (reached through the private `-[WKWebView _inspector]`
/// property). Candoa ships as a direct DMG, so no App Store private-API
/// rule applies. Every call probes with respondsToSelector first: if an
/// SDK update renames or removes any of these selectors, the menu items
/// degrade to silent no-ops instead of crashing.
@MainActor
extension WebViewCoordinator {
    // MARK: - Web Inspector

    func canInspect(tabID: UUID) -> Bool {
        hasLoadedWebView(for: tabID) && inspector(for: tabID) != nil
    }

    func showWebInspector(for tabID: UUID) {
        performInspectorCommand("show", for: tabID)
    }

    func showJavaScriptConsole(for tabID: UUID) {
        performInspectorCommand("showConsole", for: tabID)
    }

    func showPageSource(for tabID: UUID) {
        performInspectorCommand("showMainResource", for: tabID)
    }

    func showPageResources(for tabID: UUID) {
        performInspectorCommand("showResources", for: tabID)
    }

    func toggleTimelineRecording(for tabID: UUID) {
        performInspectorCommand(
            isRecordingTimeline(for: tabID) ? "stopPageProfiling" : "startPageProfiling",
            for: tabID
        )
    }

    func isRecordingTimeline(for tabID: UUID) -> Bool {
        inspectorBool("isProfilingPage", for: tabID)
    }

    func toggleElementSelection(for tabID: UUID) {
        performInspectorCommand(
            isSelectingElement(for: tabID) ? "stopElementSelection" : "startElementSelection",
            for: tabID
        )
    }

    func isSelectingElement(for tabID: UUID) -> Bool {
        inspectorBool("isElementSelectionActive", for: tabID)
    }

    // MARK: - Private-API bridging

    private func inspector(for tabID: UUID) -> NSObject? {
        guard let webView = webViews[tabID] else { return nil }
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector) else { return nil }
        return webView.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private func performInspectorCommand(_ selectorName: String, for tabID: UUID) {
        guard let webView = webViews[tabID], let inspector = inspector(for: tabID) else { return }

        // The per-session Settings gate is read once at web-view creation;
        // the Develop menu is an explicit request, so it overrides on demand.
        webView.isInspectable = true

        let selector = NSSelectorFromString(selectorName)
        guard inspector.responds(to: selector) else { return }
        _ = inspector.perform(selector)
    }

    /// `perform(_:)` boxes ObjC BOOL returns unusably, so call the method's
    /// IMP through a matching C function type instead.
    private func inspectorBool(_ selectorName: String, for tabID: UUID) -> Bool {
        guard let inspector = inspector(for: tabID) else { return false }

        let selector = NSSelectorFromString(selectorName)
        guard inspector.responds(to: selector), let method = inspector.method(for: selector) else {
            return false
        }

        let getter = unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector) -> Bool).self)
        return getter(inspector, selector)
    }
}
