import Foundation

/// Decides whether typed text is a URL to open or a search query.
enum URLResolver {
    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Already has a scheme.
        if let url = URL(string: text), let scheme = url.scheme,
           scheme == "http" || scheme == "https" {
            return url
        }

        if looksLikeDomain(text) {
            return URL(string: "https://\(text)")
        }
        return searchURL(for: text)
    }

    private static func looksLikeDomain(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("localhost") { return true }
        // host.tld with no spaces, at least one dot, a valid-ish TLD.
        guard text.contains(".") else { return false }
        let host = text.split(separator: "/").first.map(String.init) ?? text
        guard let dot = host.lastIndex(of: "."), host.distance(from: dot, to: host.endIndex) > 1 else {
            return false
        }
        let tld = host[host.index(after: dot)...]
        return tld.allSatisfy { $0.isLetter } && tld.count >= 2
    }

    private static func searchURL(for query: String) -> URL? {
        Settings.searchEngine.url(for: query)
    }
}
