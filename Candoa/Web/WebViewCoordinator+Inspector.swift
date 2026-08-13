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

    /// Safari's ⌥⌘I toggles: Show Web Inspector while closed, Close Web
    /// Inspector while open.
    func toggleWebInspector(for tabID: UUID) {
        performInspectorCommand(
            isWebInspectorVisible(for: tabID) ? "close" : "show",
            for: tabID
        )
    }

    func isWebInspectorVisible(for tabID: UUID) -> Bool {
        inspectorBool("isVisible", for: tabID)
    }

    /// Unconditionally show, for callers that already know the inspector
    /// should end up open (Develop ▸ device submenu's Inspect Page).
    func showWebInspector(for tabID: UUID) {
        performInspectorCommand("show", for: tabID)
    }

    /// Safari's Connect Web Inspector: attach the inspector backend without
    /// forcing the window forward. Older SDKs lack `connect`, in which case
    /// showing is the closest behavior rather than a silent no-op.
    func connectWebInspector(for tabID: UUID) {
        performInspectorCommand("connect", for: tabID, fallback: "show")
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

    private func performInspectorCommand(
        _ selectorName: String,
        for tabID: UUID,
        fallback fallbackSelectorName: String? = nil
    ) {
        guard let webView = webViews[tabID], let inspector = inspector(for: tabID) else { return }

        // The per-session Settings gate is read once at web-view creation;
        // the Develop menu is an explicit request, so it overrides on demand.
        webView.isInspectable = true

        var selector = NSSelectorFromString(selectorName)
        if !inspector.responds(to: selector), let fallbackSelectorName {
            selector = NSSelectorFromString(fallbackSelectorName)
        }
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

/// Safari-style feature flags, built on the private
/// `+[WKPreferences _experimentalFeatures]` enumeration (elements are
/// `_WKFeature` objects) and `-[WKPreferences _setEnabled:forExperimentalFeature:]`.
/// Same defensive posture as the inspector bridging above: every selector is
/// probed first, every KVC key is probed through its getter selector, and a
/// missing API degrades to an empty list or a no-op instead of a crash.
///
/// Overrides persist as a key → Bool dictionary in UserDefaults and are
/// applied to each WKWebViewConfiguration at web-view creation, so a change
/// only reaches web views created afterwards — matching Safari, which asks
/// for a relaunch.
@MainActor
enum WebKitFeatureFlags {
    struct Flag: Identifiable {
        let key: String
        let name: String
        let details: String?
        let defaultValue: Bool
        /// Raw `_WKFeature` status/category enums, kept as plain ints since
        /// the private enum names are not worth mirroring.
        let status: Int?
        let category: Int?

        var id: String { key }
    }

    static let overridesDefaultsKey = "Candoa.WebKitFeatureFlagOverrides"

    static func allFlags() -> [Flag] {
        featureObjects()
            .compactMap { feature -> Flag? in
                guard let key = featureValue("key", of: feature) as? String, !key.isEmpty else {
                    return nil
                }
                let name = featureValue("name", of: feature) as? String
                // Older SDKs spelled details "featureDescription".
                let details = (featureValue("details", of: feature) as? String)
                    ?? (featureValue("featureDescription", of: feature) as? String)
                return Flag(
                    key: key,
                    name: (name?.isEmpty == false) ? name! : key,
                    details: (details?.isEmpty == false) ? details : nil,
                    defaultValue: (featureValue("defaultValue", of: feature) as? NSNumber)?.boolValue ?? false,
                    status: (featureValue("status", of: feature) as? NSNumber)?.intValue,
                    category: (featureValue("category", of: feature) as? NSNumber)?.intValue
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Override persistence

    static func override(for key: String) -> Bool? {
        storedOverrides()[key]
    }

    /// Passing nil removes the override so untouched flags track WebKit's
    /// own defaults across SDK updates.
    static func setOverride(_ value: Bool?, for key: String) {
        var overrides = storedOverrides()
        overrides[key] = value
        if overrides.isEmpty {
            UserDefaults.standard.removeObject(forKey: overridesDefaultsKey)
        } else {
            UserDefaults.standard.set(overrides, forKey: overridesDefaultsKey)
        }
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: overridesDefaultsKey)
    }

    // MARK: - Applying overrides

    /// Pushes every stored override whose key still names a real feature onto
    /// the given preferences. Stale keys (features removed by an SDK update)
    /// are skipped, not pruned, so they revive if the feature returns.
    static func apply(to preferences: WKPreferences) {
        let overrides = storedOverrides()
        guard !overrides.isEmpty else { return }

        var selector = NSSelectorFromString("_setEnabled:forExperimentalFeature:")
        if !preferences.responds(to: selector) {
            // Newer SDKs fold experimental features into the plain feature setter.
            selector = NSSelectorFromString("_setEnabled:forFeature:")
        }
        guard preferences.responds(to: selector),
              let method = preferences.method(for: selector) else { return }

        // perform(_:) cannot pass an ObjC BOOL argument, so call the IMP
        // through a matching C function type (same trick as inspectorBool).
        let setter = unsafeBitCast(
            method,
            to: (@convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void).self
        )
        for feature in featureObjects() {
            guard let key = featureValue("key", of: feature) as? String,
                  let value = overrides[key] else { continue }
            setter(preferences, selector, value, feature)
        }
    }

    // MARK: - Private-API bridging

    private static func featureObjects() -> [NSObject] {
        let selector = NSSelectorFromString("_experimentalFeatures")
        let preferencesClass: AnyObject = WKPreferences.self
        guard preferencesClass.responds(to: selector) else { return [] }
        return preferencesClass.perform(selector)?.takeUnretainedValue() as? [NSObject] ?? []
    }

    /// `value(forKey:)` raises an ObjC exception on unknown keys, which Swift
    /// cannot catch; probe the getter selector before reading.
    private static func featureValue(_ key: String, of feature: NSObject) -> Any? {
        guard feature.responds(to: NSSelectorFromString(key)) else { return nil }
        return feature.value(forKey: key)
    }

    private static func storedOverrides() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: overridesDefaultsKey) as? [String: Bool] ?? [:]
    }
}
