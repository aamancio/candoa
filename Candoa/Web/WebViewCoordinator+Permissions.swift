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
