import AppKit
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
        await requestSiteMediaCapturePermission(for: origin, type: type, webView: webView)
    }

    private func requestSiteMediaCapturePermission(
        for origin: WKSecurityOrigin,
        type: WKMediaCaptureType,
        webView: WKWebView
    ) async -> WKPermissionDecision {
        let host = origin.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = host.isEmpty ? "This website" : host
        let mediaName = mediaCaptureDisplayName(for: type)

        let alert = NSAlert()
        alert.messageText = "\(siteName) wants to use \(mediaName)"
        alert.informativeText = "Allow access only if you trust this page."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")

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
            return "your camera"
        case .microphone:
            return "your microphone"
        case .cameraAndMicrophone:
            return "your camera and microphone"
        @unknown default:
            return "media capture"
        }
    }
}

