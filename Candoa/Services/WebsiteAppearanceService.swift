import Foundation
import WebKit

enum WebsiteAppearanceService {
    private static let youtubePreferenceName = "PREF"
    private static let youtubeDarkThemeValue = "400"
    private static let youtubeLightThemeValue = "0"

    static func preparesServerTheme(for url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
    }

    @MainActor
    static func prepareServerTheme(
        for url: URL,
        in dataStore: WKWebsiteDataStore,
        usesDarkAppearance: Bool,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        guard preparesServerTheme(for: url) else {
            completion()
            return
        }

        let cookieStore = dataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            let existingCookie = cookies.first {
                $0.name == youtubePreferenceName
                    && ($0.domain == "youtube.com" || $0.domain.hasSuffix(".youtube.com"))
            }
            let value = youtubePreferenceValue(
                preserving: existingCookie?.value,
                usesDarkAppearance: usesDarkAppearance
            )

            guard let cookie = youtubePreferenceCookie(value: value, preserving: existingCookie) else {
                completion()
                return
            }

            cookieStore.setCookie(cookie, completionHandler: completion)
        }
    }

    private static func youtubePreferenceValue(
        preserving existingValue: String?,
        usesDarkAppearance: Bool
    ) -> String {
        var fields = existingValue?
            .split(separator: "&")
            .map(String.init)
            .filter { !$0.hasPrefix("f6=") } ?? []
        let themeValue = usesDarkAppearance ? youtubeDarkThemeValue : youtubeLightThemeValue
        fields.append("f6=\(themeValue)")
        return fields.joined(separator: "&")
    }

    private static func youtubePreferenceCookie(
        value: String,
        preserving existingCookie: HTTPCookie?
    ) -> HTTPCookie? {
        var properties = existingCookie?.properties ?? [:]
        properties[.name] = youtubePreferenceName
        properties[.value] = value
        properties[.domain] = existingCookie?.domain ?? ".youtube.com"
        properties[.path] = existingCookie?.path ?? "/"
        properties[.secure] = "TRUE"

        if existingCookie?.expiresDate == nil {
            properties[.expires] = Calendar.current.date(byAdding: .year, value: 2, to: Date())
        }

        return HTTPCookie(properties: properties)
    }
}
