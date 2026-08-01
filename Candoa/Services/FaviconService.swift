import Foundation
import AppKit

@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private let cache = NSCache<NSURL, NSData>()
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Favicon service for private windows: fetches carry no shared cookies
    /// and write no shared URL cache, and the in-memory favicon cache dies
    /// with the window's store. URLSession.shared would leak every private
    /// page's favicon (and discovery HTML) request into the app-wide
    /// cookie and cache stores.
    static func makeEphemeral() -> FaviconService {
        FaviconService(session: URLSession(configuration: .ephemeral))
    }

    func placeholderSymbol(for url: URL?) -> String {
        guard let host = url?.host(percentEncoded: false)?.lowercased() else {
            return "globe"
        }

        if host.contains("github") { return "chevron.left.forwardslash.chevron.right" }
        if host.contains("google") { return "magnifyingglass" }
        if host.contains("apple") { return "apple.logo" }
        if host.contains("localhost") { return "server.rack" }
        return "globe"
    }

    func faviconData(for pageURL: URL?, candidateURL: URL?) async -> Data? {
        var candidates = faviconCandidates(pageURL: pageURL, candidateURL: candidateURL)
        if candidateURL == nil, let pageURL {
            candidates.append(contentsOf: await discoverIconCandidates(from: pageURL))
        }

        for url in candidates {
            if let cachedData = cache.object(forKey: url as NSURL) {
                return cachedData as Data
            }

            guard let fetchedData = await fetchImageData(from: url) else { continue }
            cache.setObject(fetchedData as NSData, forKey: url as NSURL)
            return fetchedData
        }

        return nil
    }

    private func discoverIconCandidates(from pageURL: URL) async -> [URL] {
        guard pageURL.scheme?.hasPrefix("http") == true else { return [] }

        do {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 8
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
                contentType.contains("html"),
                let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii)
            else {
                return []
            }

            return iconCandidates(in: html, relativeTo: pageURL)
        } catch {
            return []
        }
    }

    private func iconCandidates(in html: String, relativeTo pageURL: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<link\b[^>]*>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let urls = regex.matches(in: html, range: range).compactMap { match -> URL? in
            guard
                let tagRange = Range(match.range, in: html),
                let rel = attributeValue(named: "rel", in: String(html[tagRange]))?.lowercased(),
                rel.contains("icon"),
                let href = attributeValue(named: "href", in: String(html[tagRange]))
            else {
                return nil
            }

            return URL(string: href, relativeTo: pageURL)?.absoluteURL
        }

        return Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
    }

    private func attributeValue(named name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let regex = try? NSRegularExpression(
            pattern: #"\b\#(escapedName)\s*=\s*(["'])(.*?)\1"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard
            let match = regex.firstMatch(in: tag, range: range),
            match.numberOfRanges > 2,
            let valueRange = Range(match.range(at: 2), in: tag)
        else {
            return nil
        }

        return String(tag[valueRange])
    }

    private func faviconCandidates(pageURL: URL?, candidateURL: URL?) -> [URL] {
        var urls: [URL] = []

        if let candidateURL {
            urls.append(candidateURL)
        }

        if let pageURL, let scheme = pageURL.scheme, let host = pageURL.host(percentEncoded: false) {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host
            components.port = pageURL.port
            components.path = "/favicon.ico"

            if let faviconURL = components.url {
                urls.append(faviconURL)
            }
        }

        return Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
    }

    private func fetchImageData(from url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            let (data, response) = try await session.data(for: request)
            guard
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode),
                data.count > 0,
                NSImage(data: data) != nil
            else {
                return nil
            }

            return data
        } catch {
            return nil
        }
    }
}
