import AppKit
import AuthenticationServices
import Foundation

@MainActor
final class CandoaAppleSignInService: NSObject {
    private var authenticationSession: ASWebAuthenticationSession?

    func authenticate(at url: URL) async throws -> String {
        guard authenticationSession == nil else {
            throw CandoaAccountError.server("Sign in with Apple is already in progress.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "candoa"
            ) { [weak self] callbackURL, error in
                Task { @MainActor in
                    self?.authenticationSession = nil

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let callbackURL,
                          callbackURL.scheme == "candoa",
                          callbackURL.host == "auth",
                          callbackURL.path == "/apple",
                          let components = URLComponents(
                            url: callbackURL,
                            resolvingAgainstBaseURL: false
                          ) else {
                        continuation.resume(throwing: CandoaAccountError.invalidResponse)
                        return
                    }
                    let values = Dictionary(
                        uniqueKeysWithValues: components.queryItems?.compactMap { item in
                            item.value.map { (item.name, $0) }
                        } ?? []
                    )
                    if let code = values["code"], !code.isEmpty {
                        continuation.resume(returning: code)
                    } else {
                        let message = values["error"]
                            .map(Self.readableError)
                            ?? "Candoa could not complete Sign in with Apple."
                        continuation.resume(throwing: CandoaAccountError.server(message))
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session

            if !session.start() {
                authenticationSession = nil
                continuation.resume(
                    throwing: CandoaAccountError.server(
                        "Candoa could not open Sign in with Apple."
                    )
                )
            }
        }
    }

    private static func readableError(_ value: String) -> String {
        switch value {
        case "access_denied":
            return "Sign in with Apple was canceled."
        case "apple_account_not_linked":
            return "Apple could not be connected to this Candoa account."
        default:
            return "Candoa could not complete Sign in with Apple."
        }
    }
}

extension CandoaAppleSignInService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first
            ?? ASPresentationAnchor()
    }
}
