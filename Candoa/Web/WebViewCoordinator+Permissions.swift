import AppKit
import Security
import WebKit

// In an extension to avoid a spurious near-match warning against the
// deprecated decideMediaCapturePermissionsFor requirement.
extension WebViewCoordinator {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType
    ) async -> WKPermissionDecision {
        // A stored Site Info decision answers without prompting; "Ask"
        // (the default) falls through to the per-request sheet.
        if let originKey = SitePermissionConfiguration.originKey(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port
        ) {
            let decisions = mediaCapturePermissions(for: type).map {
                SitePermissionConfiguration.decision(for: $0, originKey: originKey)
            }
            if decisions.contains(.deny) {
                return .deny
            }
            if !decisions.isEmpty, decisions.allSatisfy({ $0 == .allow }) {
                return .grant
            }
        }

        return await requestSiteMediaCapturePermission(for: origin, type: type, webView: webView)
    }

    private func mediaCapturePermissions(for type: WKMediaCaptureType) -> [SitePermission] {
        switch type {
        case .camera:
            return [.camera]
        case .microphone:
            return [.microphone]
        case .cameraAndMicrophone:
            return [.camera, .microphone]
        @unknown default:
            return []
        }
    }

    private func requestSiteMediaCapturePermission(
        for origin: WKSecurityOrigin,
        type: WKMediaCaptureType,
        webView: WKWebView
    ) async -> WKPermissionDecision {
        let host = origin.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = host.isEmpty ? String(localized: "This website") : host
        let mediaName = mediaCaptureDisplayName(for: type)

        let alert = NSAlert()
        alert.messageText = String(localized: "\(siteName) wants to use \(mediaName)")
        alert.informativeText = String(localized: "Allow access only if you trust this page.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))

        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }

        return response == .alertFirstButtonReturn ? .grant : .deny
    }

    private func mediaCaptureDisplayName(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera:
            return String(localized: "your camera")
        case .microphone:
            return String(localized: "your microphone")
        case .cameraAndMicrophone:
            return String(localized: "your camera and microphone")
        @unknown default:
            return String(localized: "media capture")
        }
    }

    // MARK: - Web Notifications

    /// The shim's side of the Notification API: permission queries and
    /// requests, showing, and closing. Main frame only — matching where the
    /// shim is injected — and everything is keyed to the frame's own
    /// security origin, never to page-supplied strings.
    func handleWebNotificationMessage(
        _ message: WKScriptMessage,
        tabID: UUID,
        webView: WKWebView
    ) {
        guard
            message.frameInfo.isMainFrame,
            let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else { return }

        let origin = message.frameInfo.securityOrigin
        let originKey = SitePermissionConfiguration.originKey(
            scheme: origin.protocol,
            host: origin.host,
            port: origin.port
        )

        switch action {
        case "query":
            pushNotificationPermissionState(to: webView, originKey: originKey)

        case "requestPermission":
            guard let requestID = Self.pageNotificationID(from: body["requestID"]) else { return }
            resolveNotificationPermissionRequest(
                requestID: requestID,
                originKey: originKey,
                host: origin.host,
                webView: webView
            )

        case "show":
            guard
                !isPrivate,
                let originKey,
                SitePermissionConfiguration.decision(
                    for: .notifications, originKey: originKey
                ) == .allow,
                let id = Self.pageNotificationID(from: body["id"])
            else { return }
            WebNotificationService.shared.show(
                pageNotificationID: id,
                title: body["title"] as? String ?? "",
                body: body["body"] as? String ?? "",
                tag: body["tag"] as? String ?? "",
                originKey: originKey,
                host: origin.host,
                tabID: tabID
            )

        case "close":
            guard let id = Self.pageNotificationID(from: body["id"]) else { return }
            WebNotificationService.shared.close(pageNotificationID: id, tabID: tabID)

        default:
            break
        }
    }

    /// Answers the shim's load-time query — and every main-frame commit —
    /// with the origin's stored decision, correcting the shim's provisional
    /// "default". Private windows always read denied: a notification in
    /// Notification Center would outlive and reveal the private session.
    func pushNotificationPermissionState(to webView: WKWebView, originKey: String? = nil) {
        let key = originKey ?? webView.url.flatMap(SitePermissionConfiguration.originKey(for:))
        let state: String
        if isPrivate {
            state = "denied"
        } else if let key {
            switch SitePermissionConfiguration.decision(for: .notifications, originKey: key) {
            case .allow: state = "granted"
            case .deny: state = "denied"
            case .ask: state = "default"
            }
        } else {
            state = "denied"
        }
        webView.evaluateJavaScript(
            "window.__candoaNotificationPermissionUpdate && window.__candoaNotificationPermissionUpdate('\(state)')",
            completionHandler: nil
        )
    }

    private func resolveNotificationPermissionRequest(
        requestID: String,
        originKey: String?,
        host: String,
        webView: WKWebView
    ) {
        func respond(_ state: String) {
            webView.evaluateJavaScript(
                "window.__candoaNotificationPermissionResult && window.__candoaNotificationPermissionResult('\(requestID)', '\(state)')",
                completionHandler: nil
            )
        }

        guard !isPrivate, let originKey else {
            respond("denied")
            return
        }

        switch SitePermissionConfiguration.decision(for: .notifications, originKey: originKey) {
        case .allow:
            respond("granted")
        case .deny:
            respond("denied")
        case .ask:
            Task { @MainActor in
                let granted = await promptForNotificationPermission(host: host, webView: webView)
                // Persisted, like Safari: one grant answers the site until
                // the person changes it in Site Info.
                if let url = URL(string: originKey) {
                    SitePermissionConfiguration.setDecision(
                        granted ? .allow : .deny, for: .notifications, url: url
                    )
                }
                if granted {
                    WebNotificationService.shared.requestAuthorizationIfNeeded()
                }
                respond(granted ? "granted" : "denied")
            }
        }
    }

    private func promptForNotificationPermission(host: String, webView: WKWebView) async -> Bool {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = trimmedHost.isEmpty ? String(localized: "This website") : trimmedHost

        let alert = NSAlert()
        alert.messageText = String(localized: "\(siteName) wants to send you notifications")
        alert.informativeText = String(
            localized: "Notifications appear in Notification Center while the site is open in a tab. You can change this later in Site Info."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Allow"))
        alert.addButton(withTitle: String(localized: "Don't Allow"))

        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn
    }

    /// The shim's ids are its own monotonically increasing integers; anything
    /// else is a page trying to smuggle script into an `evaluateJavaScript`
    /// round trip and is dropped.
    nonisolated static func pageNotificationID(from value: Any?) -> String? {
        guard
            let id = value as? String,
            !id.isEmpty, id.count <= 12,
            id.allSatisfy(\.isNumber)
        else { return nil }
        return id
    }

    /// Lets the page whose notification was clicked dispatch its `click`
    /// event, after the window and tab have already been focused.
    func dispatchWebNotificationClick(pageNotificationID: String, tabID: UUID) {
        guard
            Self.pageNotificationID(from: pageNotificationID) != nil,
            let webView = webViews[tabID]
        else { return }
        webView.evaluateJavaScript(
            "window.__candoaNotificationActivated && window.__candoaNotificationActivated('\(pageNotificationID)')",
            completionHandler: nil
        )
    }

    // MARK: - Site Info security summary

    /// A one-shot read of the displayed page's security state for the Site
    /// Info popover. Computed on demand from the live web view — no
    /// observation, polling, or retained page state.
    func siteSecuritySummary(forTabID tabID: UUID) -> SiteSecuritySummary? {
        guard let webView = webViews[tabID], let url = webView.url else { return nil }

        if url.isFileURL {
            return SiteSecuritySummary(
                connection: .localFile,
                certificateSubject: nil,
                certificateExpiry: nil
            )
        }

        if url.isLocalDevelopment {
            return SiteSecuritySummary(
                connection: .localDevelopment,
                certificateSubject: nil,
                certificateExpiry: nil
            )
        }

        guard url.scheme?.lowercased() == "https" else {
            return SiteSecuritySummary(
                connection: .insecure,
                certificateSubject: nil,
                certificateExpiry: nil
            )
        }

        let leafCertificate = webView.serverTrust.flatMap {
            (SecTrustCopyCertificateChain($0) as? [SecCertificate])?.first
        }
        return SiteSecuritySummary(
            connection: webView.hasOnlySecureContent ? .secure : .mixedContent,
            certificateSubject: leafCertificate.flatMap {
                SecCertificateCopySubjectSummary($0) as String?
            },
            certificateExpiry: leafCertificate.flatMap(Self.certificateNotAfterDate)
        )
    }

    /// Reads the leaf certificate's not-after date through the macOS
    /// certificate-values API; nil when the property cannot be read.
    private static func certificateNotAfterDate(from certificate: SecCertificate) -> Date? {
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard
            let values = SecCertificateCopyValues(certificate, keys, nil)
                as? [String: [String: Any]],
            let notAfter = values[kSecOIDX509V1ValidityNotAfter as String],
            let seconds = notAfter[kSecPropertyKeyValue as String] as? NSNumber
        else {
            return nil
        }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }
}
