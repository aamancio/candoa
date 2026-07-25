import AppKit
@preconcurrency import AuthenticationServices
import Foundation

struct CandoaPasskeyRegistrationOptions: Decodable, Sendable {
    struct RelyingParty: Decodable, Sendable {
        let id: String
    }

    struct User: Decodable, Sendable {
        let id: String
        let name: String
        let displayName: String
    }

    struct CredentialDescriptor: Decodable, Sendable {
        let id: String
    }

    let challenge: String
    let rp: RelyingParty
    let user: User
    let excludeCredentials: [CredentialDescriptor]?
}

struct CandoaPasskeyAuthenticationOptions: Decodable, Sendable {
    struct CredentialDescriptor: Decodable, Sendable {
        let id: String
    }

    let challenge: String
    let rpID: String?
    let allowCredentials: [CredentialDescriptor]?

    private enum CodingKeys: String, CodingKey {
        case challenge
        case rpID = "rpId"
        case allowCredentials
    }
}

struct CandoaPasskeyRegistrationCredential: Encodable, Sendable {
    struct Response: Encodable, Sendable {
        let clientDataJSON: String
        let attestationObject: String
        let transports = ["internal"]
    }

    let id: String
    let rawID: String
    let response: Response
    let type = "public-key"
    let authenticatorAttachment = "platform"
    let clientExtensionResults = EmptyObject()

    private enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case response
        case type
        case authenticatorAttachment
        case clientExtensionResults
    }
}

struct CandoaPasskeyAuthenticationCredential: Encodable, Sendable {
    struct Response: Encodable, Sendable {
        let clientDataJSON: String
        let authenticatorData: String
        let signature: String
        let userHandle: String
    }

    let id: String
    let rawID: String
    let response: Response
    let type = "public-key"
    let authenticatorAttachment = "platform"
    let clientExtensionResults = EmptyObject()

    private enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case response
        case type
        case authenticatorAttachment
        case clientExtensionResults
    }
}

struct CandoaPasskeyVerificationRequest<Response: Encodable>: Encodable {
    let response: Response
}

struct EmptyObject: Encodable, Sendable {}

@MainActor
final class CandoaPasskeyService: NSObject {
    private struct SendableAuthorizationCredential: @unchecked Sendable {
        let value: any ASAuthorizationCredential
    }

    private var authorizationController: ASAuthorizationController?
    private var continuation: CheckedContinuation<SendableAuthorizationCredential, any Error>?
    private var presentationWindow: NSWindow?

    func createPasskey(
        options: CandoaPasskeyRegistrationOptions
    ) async throws -> CandoaPasskeyRegistrationCredential {
        guard let challenge = Data(base64URLEncoded: options.challenge),
              let userID = Data(base64URLEncoded: options.user.id) else {
            throw CandoaAccountError.invalidResponse
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: options.rp.id
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: options.user.name,
            userID: userID
        )
        request.displayName = options.user.displayName
        request.userVerificationPreference = .required
        request.excludedCredentials = (options.excludeCredentials ?? []).compactMap { descriptor in
            Data(base64URLEncoded: descriptor.id).map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }

        let credential = try await perform(request)
        guard let registration =
                credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestationObject = registration.rawAttestationObject else {
            throw CandoaAccountError.passkeyUnavailable
        }

        let credentialID = registration.credentialID.base64URLEncodedString()
        return CandoaPasskeyRegistrationCredential(
            id: credentialID,
            rawID: credentialID,
            response: .init(
                clientDataJSON: registration.rawClientDataJSON.base64URLEncodedString(),
                attestationObject: attestationObject.base64URLEncodedString()
            )
        )
    }

    func signIn(
        options: CandoaPasskeyAuthenticationOptions
    ) async throws -> CandoaPasskeyAuthenticationCredential {
        guard let challenge = Data(base64URLEncoded: options.challenge) else {
            throw CandoaAccountError.invalidResponse
        }

        let relyingPartyID = options.rpID ?? "www.candoa.app"
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyID
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = (options.allowCredentials ?? []).compactMap { descriptor in
            Data(base64URLEncoded: descriptor.id).map {
                ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
            }
        }
        request.shouldShowHybridTransport = true

        let credential = try await perform(request)
        guard let assertion =
                credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw CandoaAccountError.passkeyUnavailable
        }

        let credentialID = assertion.credentialID.base64URLEncodedString()
        return CandoaPasskeyAuthenticationCredential(
            id: credentialID,
            rawID: credentialID,
            response: .init(
                clientDataJSON: assertion.rawClientDataJSON.base64URLEncodedString(),
                authenticatorData: assertion.rawAuthenticatorData.base64URLEncodedString(),
                signature: assertion.signature.base64URLEncodedString(),
                userHandle: assertion.userID.base64URLEncodedString()
            )
        )
    }

    private func perform(
        _ request: ASAuthorizationRequest
    ) async throws -> any ASAuthorizationCredential {
        guard continuation == nil else {
            throw CandoaAccountError.passkeyUnavailable
        }
        guard let window = NSApp.keyWindow
                ?? NSApp.mainWindow
                ?? NSApp.windows.first(where: { $0.isVisible }) else {
            throw CandoaAccountError.passkeyUnavailable
        }

        presentationWindow = window
        let credential = try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            authorizationController = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
        return credential.value
    }

    private func finish(returning credential: any ASAuthorizationCredential) {
        let continuation = continuation
        self.continuation = nil
        authorizationController = nil
        presentationWindow = nil
        continuation?.resume(
            returning: SendableAuthorizationCredential(value: credential)
        )
    }

    private func finish(throwing error: any Error) {
        let continuation = continuation
        self.continuation = nil
        authorizationController = nil
        presentationWindow = nil
        continuation?.resume(throwing: error)
    }
}

extension CandoaPasskeyService: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(returning: authorization.credential)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: any Error
    ) {
        finish(throwing: error)
    }
}

extension CandoaPasskeyService: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        presentationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow ?? NSWindow()
    }
}

private extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
