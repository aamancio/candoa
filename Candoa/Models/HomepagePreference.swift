import Foundation

/// The address the History menu's Home command opens.
///
/// Candoa had no homepage before this; the default is the home page of the
/// chosen search engine, which is where Home lands in every browser that ships
/// one and needs no setup from the person.
enum HomepagePreference {
    static var storedValue: String {
        UserDefaults.standard.string(forKey: SettingsOption.homepage) ?? ""
    }

    /// The resolved destination: whatever is stored, or the default search
    /// engine's own site. Nil only when neither can be turned into a URL.
    static var url: URL? {
        let trimmed = storedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let url = normalized(trimmed) {
            return url
        }
        return defaultURL
    }

    static var defaultURL: URL? {
        let providerID = UserDefaults.standard.string(forKey: SettingsOption.defaultSearchProvider)
        let provider = providerID.flatMap(NavigationService.searchProvider(id:))
            ?? NavigationService.searchProviders.first
        guard let host = provider?.homeURL else { return URL(string: "https://www.google.com") }
        return host
    }

    /// Accepts what someone would actually type — "example.com" as readily as
    /// a full URL — and refuses anything that is not a web address, so Home
    /// cannot be pointed at a file or a custom scheme.
    static func normalized(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false),
              host.contains(".")
        else {
            return nil
        }
        return url
    }
}
