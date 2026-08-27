import AppKit
import CryptoKit
import LocalAuthentication
import WebKit

/// The native half of the built-in passkey authenticator (issue #506): the
/// shim marshals `navigator.credentials` calls here, and this side owns
/// everything security-relevant — the origin comes from WebKit's frame info,
/// never from page-supplied strings; consent is a Touch ID (or password)
/// prompt; keys never leave the keychain. Replies travel back through
/// `__candoaPasskeyResult`, matched by the shim's numeric request ids.
extension WebViewCoordinator {
    func handlePasskeyMessage(_ message: WKScriptMessage, webView: WKWebView) {
        guard
            let body = message.body as? [String: Any],
            let action = body["action"] as? String,
            let requestID = Self.passkeyRequestID(from: body["requestID"])
        else { return }

        if action == "cancel" {
            if activePasskeyRequestID == requestID {
                activePasskeyAuthenticationContext?.invalidate()
            }
            return
        }

        func respond(_ reply: [String: Any]) {
            respondToPasskeyRequest(requestID, reply: reply, webView: webView)
        }

        guard message.frameInfo.isMainFrame, let origin = Self.originURL(of: message.frameInfo) else {
            respond(Self.passkeyFailure("NotAllowedError"))
            return
        }
        guard activePasskeyRequestID == nil else {
            respond(Self.passkeyFailure(
                "NotAllowedError", message: "A passkey request is already in progress."
            ))
            return
        }

        activePasskeyRequestID = requestID
        Task { @MainActor in
            defer {
                activePasskeyRequestID = nil
                activePasskeyAuthenticationContext = nil
            }
            switch action {
            case "create":
                respond(await createPasskey(body: body, origin: origin, webView: webView))
            case "get":
                respond(await assertPasskey(body: body, origin: origin, webView: webView))
            default:
                respond(Self.passkeyFailure("NotSupportedError"))
            }
        }
    }

    // MARK: - Registration

    private func createPasskey(
        body: [String: Any],
        origin: URL,
        webView: WKWebView
    ) async -> [String: Any] {
        guard let relyingParty = try? PasskeyCeremony.effectiveRelyingParty(
            requested: body["rpId"] as? String, origin: origin
        ) else {
            return Self.passkeyFailure(
                "SecurityError", message: "The relying party ID is not valid for this origin."
            )
        }
        let algorithms = (body["algorithms"] as? [Int]) ?? []
        guard algorithms.contains(PasskeyCeremony.supportedAlgorithm) else {
            return Self.passkeyFailure(
                "NotSupportedError", message: "None of the requested algorithms are supported."
            )
        }
        guard
            let challenge = body["challenge"] as? String,
            let userHandle = body["userId"] as? String
        else {
            return Self.passkeyFailure("NotAllowedError")
        }

        let existing = passkeyCredentials.credentials(for: relyingParty)
        let excluded = Set((body["excludeCredentials"] as? [String]) ?? [])
        if existing.contains(where: { excluded.contains($0.id) }) {
            return Self.passkeyFailure(
                "InvalidStateError", message: "A passkey already exists for this account."
            )
        }

        let userName = (body["userName"] as? String) ?? ""
        let verified = await verifyUser(reason: String(
            localized: "save a passkey for “\(relyingParty)”"
        ))
        guard verified else { return Self.passkeyFailure("NotAllowedError") }

        let key = P256.Signing.PrivateKey()
        var identifier = Data(count: 32)
        identifier.withUnsafeMutableBytes { buffer in
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        let credential = PasskeyCredential(
            id: PasskeyCeremony.base64URLEncode(identifier),
            relyingParty: relyingParty,
            userHandle: userHandle,
            userName: userName,
            userDisplayName: (body["userDisplayName"] as? String) ?? "",
            privateKey: key.rawRepresentation,
            createdAt: Date()
        )
        do {
            try passkeyCredentials.save(credential)
        } catch {
            return Self.passkeyFailure("UnknownError", message: "The passkey could not be saved.")
        }

        let clientData = PasskeyCeremony.clientDataJSON(
            type: "webauthn.create", challenge: challenge, origin: origin
        )
        let authenticatorData = PasskeyCeremony.authenticatorData(
            relyingParty: relyingParty,
            flags: [
                .userPresent, .userVerified, .backupEligible, .backedUp,
                .attestedCredentialIncluded
            ],
            attestedCredential: (id: identifier, publicKey: key.publicKey)
        )
        return [
            "credentialId": credential.id,
            "clientDataJSON": PasskeyCeremony.base64URLEncode(clientData),
            "attestationObject": PasskeyCeremony.base64URLEncode(
                PasskeyCeremony.attestationObject(authenticatorData: authenticatorData)
            ),
            "authenticatorData": PasskeyCeremony.base64URLEncode(authenticatorData),
            "publicKey": PasskeyCeremony.base64URLEncode(key.publicKey.derRepresentation),
            "publicKeyAlgorithm": PasskeyCeremony.supportedAlgorithm
        ]
    }

    // MARK: - Assertion

    private func assertPasskey(
        body: [String: Any],
        origin: URL,
        webView: WKWebView
    ) async -> [String: Any] {
        guard let relyingParty = try? PasskeyCeremony.effectiveRelyingParty(
            requested: body["rpId"] as? String, origin: origin
        ) else {
            return Self.passkeyFailure(
                "SecurityError", message: "The relying party ID is not valid for this origin."
            )
        }
        guard let challenge = body["challenge"] as? String else {
            return Self.passkeyFailure("NotAllowedError")
        }

        var candidates = passkeyCredentials.credentials(for: relyingParty)
        let allowed = Set((body["allowCredentials"] as? [String]) ?? [])
        if !allowed.isEmpty {
            candidates = candidates.filter { allowed.contains($0.id) }
        }
        guard !candidates.isEmpty else {
            return Self.passkeyFailure(
                "NotAllowedError", message: "No matching passkey is saved in Candoa."
            )
        }

        guard let credential = await choosePasskey(
            from: candidates, relyingParty: relyingParty, webView: webView
        ) else {
            return Self.passkeyFailure("NotAllowedError")
        }
        guard let key = credential.signingKey else {
            return Self.passkeyFailure("UnknownError", message: "The passkey could not be read.")
        }

        let verified = await verifyUser(reason: String(
            localized: "sign in to “\(relyingParty)” with a saved passkey"
        ))
        guard verified else { return Self.passkeyFailure("NotAllowedError") }

        let clientData = PasskeyCeremony.clientDataJSON(
            type: "webauthn.get", challenge: challenge, origin: origin
        )
        let authenticatorData = PasskeyCeremony.authenticatorData(
            relyingParty: relyingParty,
            flags: [.userPresent, .userVerified, .backupEligible, .backedUp]
        )
        guard let signature = try? PasskeyCeremony.assertionSignature(
            privateKey: key,
            authenticatorData: authenticatorData,
            clientDataJSON: clientData
        ) else {
            return Self.passkeyFailure("UnknownError", message: "The assertion could not be signed.")
        }
        return [
            "credentialId": credential.id,
            "clientDataJSON": PasskeyCeremony.base64URLEncode(clientData),
            "authenticatorData": PasskeyCeremony.base64URLEncode(authenticatorData),
            "signature": PasskeyCeremony.base64URLEncode(signature),
            "userHandle": credential.userHandle
        ]
    }

    /// One credential answers directly; several ask the person which account,
    /// the way Safari's sheet lists a site's passkeys.
    private func choosePasskey(
        from candidates: [PasskeyCredential],
        relyingParty: String,
        webView: WKWebView
    ) async -> PasskeyCredential? {
        guard candidates.count > 1 else { return candidates.first }

        let alert = NSAlert()
        alert.messageText = String(localized: "Sign in to “\(relyingParty)”")
        alert.informativeText = String(
            localized: "Choose which passkey saved in Candoa to sign in with."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Continue"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 25))
        for candidate in candidates {
            let title = candidate.userName.isEmpty
                ? candidate.userDisplayName
                : candidate.userName
            picker.addItem(withTitle: title.isEmpty ? candidate.id : title)
        }
        alert.accessoryView = picker

        let response: NSApplication.ModalResponse
        if let window = webView.window {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return nil }
        let index = picker.indexOfSelectedItem
        guard candidates.indices.contains(index) else { return candidates.first }
        return candidates[index]
    }

    /// Touch ID with password fallback — user verification in WebAuthn
    /// terms. Fixture runs approve silently; there is no biometric prompt a
    /// test could answer.
    private func verifyUser(reason: String) async -> Bool {
        if BrowserStore.isUITesting { return true }
        let context = LAContext()
        activePasskeyAuthenticationContext = context
        return (try? await context.evaluatePolicy(
            .deviceOwnerAuthentication, localizedReason: reason
        )) ?? false
    }

    // MARK: - Reply plumbing

    private func respondToPasskeyRequest(
        _ requestID: String,
        reply: [String: Any],
        webView: WKWebView
    ) {
        // The whole call is serialized as one JSON array, so nothing
        // page-visible is ever string-concatenated into script.
        guard
            let data = try? JSONSerialization.data(withJSONObject: [requestID, reply]),
            let arguments = String(data: data, encoding: .utf8)
        else { return }
        webView.evaluateJavaScript(
            "window.__candoaPasskeyResult && window.__candoaPasskeyResult.apply(null, \(arguments))",
            completionHandler: nil
        )
    }

    private static func passkeyFailure(_ name: String, message: String? = nil) -> [String: Any] {
        var failure: [String: Any] = ["error": name]
        if let message { failure["message"] = message }
        return failure
    }

    /// Same discipline as the notification shim's ids: the shim counts up
    /// from one, so anything but a short digit run is a page trying to
    /// smuggle script into the reply round trip.
    nonisolated static func passkeyRequestID(from value: Any?) -> String? {
        guard
            let id = value as? String,
            !id.isEmpty, id.count <= 12,
            id.allSatisfy(\.isNumber)
        else { return nil }
        return id
    }

    nonisolated static func originURL(of frameInfo: WKFrameInfo) -> URL? {
        let origin = frameInfo.securityOrigin
        var components = URLComponents()
        components.scheme = origin.protocol
        components.host = origin.host
        if origin.port != 0 { components.port = Int(origin.port) }
        guard !origin.host.isEmpty else { return nil }
        return components.url
    }
}
