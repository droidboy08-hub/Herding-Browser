import Foundation

/// What the user typed turned out to be.
enum OmniboxInput: Equatable {
    /// A place to go, already normalised (scheme added, host lowercased).
    case url(URL)
    /// A query, already turned into the current search engine's results URL.
    case search(URL, query: String)

    var url: URL {
        switch self {
        case .url(let url):          return url
        case .search(let url, _):    return url
        }
    }
}

/// Decides whether text typed in the start box is somewhere to navigate or
/// something to search for.
///
/// The rules follow what address bars actually do, in order: an explicit scheme
/// wins; anything with whitespace is a search; then the text has to *look* like a
/// host — a dotted name with a plausible TLD, an IPv4 address, or localhost —
/// before it's treated as one. Everything else is a search, because guessing
/// wrong toward "navigate" sends the user's query to a DNS lookup, while guessing
/// wrong toward "search" is one click to recover.
enum OmniboxParser {

    // MARK: - Patterns

    /// `scheme://` — RFC 3986 scheme characters.
    private static let schemePattern = #"^[a-zA-Z][a-zA-Z0-9+.\-]*:"#

    /// A dotted host with a structurally valid TLD, optional port and path.
    ///
    /// The TLD is validated by shape rather than against the IANA list: 2–63
    /// letters, or a punycode `xn--` label. A bundled list would be exact today
    /// and wrong the moment a new TLD is delegated, and the cost of being wrong
    /// here is only that a typo searches instead of failing to resolve.
    private static let hostPattern = """
        ^(?:[a-z0-9](?:[a-z0-9\\-_]{0,61}[a-z0-9])?\\.)+\
        (?:[a-z]{2,63}|xn--[a-z0-9\\-]{2,59})\
        (?::\\d{1,5})?(?:[/?#].*)?$
        """

    /// Dotted-quad address, optional port and path. Octet ranges are checked
    /// separately — regex is the wrong tool for 0–255.
    private static let ipv4Pattern = #"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?::\d{1,5})?(?:[/?#].*)?$"#

    /// `localhost`, with optional port and path — the one dotless host worth
    /// special-casing, since developers type it constantly.
    private static let localhostPattern = #"^localhost(?::\d{1,5})?(?:[/?#].*)?$"#

    // MARK: - Parsing

    /// Classify raw input. Returns nil only for empty input or text that can't be
    /// turned into any valid URL.
    static func parse(_ raw: String, engine: SearchEngine = Settings.searchEngine) -> OmniboxInput? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // 1. An explicit scheme is the user being unambiguous. Only http(s) is a
        //    navigation; anything else (mailto:, javascript:, custom app schemes)
        //    is not something the start box should launch, so it searches.
        if matches(schemePattern, text) {
            guard let url = URL(string: encodeIfNeeded(text)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host?.isEmpty == false else {
                return search(text, engine: engine)
            }
            return .url(url)
        }

        // 2. Whitespace means a query. No host contains a space, and a user who
        //    typed one is searching.
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return search(text, engine: engine)
        }

        // The setting lets the user force everything through search.
        guard Settings.typedURLsOpenAsURLs else { return search(text, engine: engine) }

        // 3. An "@" before any path means an email address far more often than a
        //    URL with credentials — and userinfo in a typed URL is a classic
        //    phishing shape, so it isn't worth honouring here.
        let beforePath = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)[0]
        if beforePath.contains("@") {
            return search(text, engine: engine)
        }

        // 4. Host shapes.
        let lowered = text.lowercased()
        if matches(localhostPattern, lowered) || isIPv4(lowered) || matches(hostPattern, lowered) {
            guard let url = URL(string: "https://\(encodeIfNeeded(text))") else {
                return search(text, engine: engine)
            }
            return .url(url)
        }

        return search(text, engine: engine)
    }

    /// Convenience for callers that only need somewhere to navigate.
    static func resolve(_ raw: String, engine: SearchEngine = Settings.searchEngine) -> URL? {
        parse(raw, engine: engine)?.url
    }

    // MARK: - Helpers

    private static func search(_ query: String, engine: SearchEngine) -> OmniboxInput? {
        // `SearchEngine` builds the URL through URLComponents, so the query is
        // percent-encoded correctly — including "&", "+" and "#".
        guard let url = engine.url(for: query) else { return nil }
        return .search(url, query: query)
    }

    /// Percent-encode anything a URL can't hold literally (spaces are already
    /// ruled out by this point; this covers unicode and stray characters).
    private static func encodeIfNeeded(_ text: String) -> String {
        if URL(string: text) != nil { return text }
        return text.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? text
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Structure from the regex, range from Swift — "999.1.1.1" matches the
    /// shape but is not an address.
    private static func isIPv4(_ text: String) -> Bool {
        guard let match = text.range(of: ipv4Pattern, options: .regularExpression),
              match.lowerBound == text.startIndex else { return false }
        let host = text.split(separator: "/", maxSplits: 1)[0]
            .split(separator: ":", maxSplits: 1)[0]
        let octets = host.split(separator: ".")
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return true
        }
    }
}

/// The previous name for this parser. Kept so existing call sites read the same.
typealias URLResolver = OmniboxParser

extension URL {
    /// The address as a person would read it: no scheme, no "www.", no trailing
    /// slash — but the path and query kept, because that is the part that says
    /// *which* page it was.
    var displayAddress: String {
        var text = absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        if text.hasPrefix("www.") { text.removeFirst(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.isEmpty ? absoluteString : text
    }

    /// A real page the browser can navigate back to — as opposed to about:blank,
    /// a data: or blob: URL, or an internal scheme. Anything else is transient
    /// and must never be written into a tab as where that tab was.
    var isWebPage: Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && host?.isEmpty == false
    }
}
