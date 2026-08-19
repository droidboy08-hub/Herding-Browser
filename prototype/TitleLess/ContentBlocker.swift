import CryptoKit
import Foundation
import WebKit

/// A filter list shipped with the app.
///
/// The lists are plain text data files, not code, which is what keeps updating
/// them over the network compatible with App Store guideline 2.5.2. The
/// scriptlets that cosmetic filtering injects are the opposite — those are code
/// and must stay compiled into the binary.
enum FilterListSource: String, CaseIterable {
    case easylist
    case easyprivacy
    /// Supplemental ad and tracker rules, and the mobile-targeted subset of
    /// them, from the community lists this app bundles.
    case supplementalAds = "supplemental-ads"
    case mobileSpecific = "mobile-specific"
    /// First-party trackers — analytics a site serves from its own domain.
    /// Only the top level blocks these.
    case firstPartyTrackers = "firstparty-trackers"
    /// Hosts known to be CNAME-cloaked trackers: `metrics.example.com` that
    /// resolves, one DNS hop later, to a tracking company. See
    /// `exemptsFirstParty` for why this list is the one exception to the
    /// first-party rule.
    case cnameTrackers = "cname-trackers"
    /// Cookie-consent banners. Its own toggle, because hiding a consent dialog
    /// is a choice about *content*, not about tracking.
    case cookieNotices = "cookie-notices"
    /// Exception lists. Almost nothing but `@@` rules: they exist to put back
    /// what the block lists take away — the login button, the video player, the
    /// site's own banner. They load at every level that blocks anything at all,
    /// and they matter most at the levels that block most.
    case siteFixes = "site-fixes"
    /// Rules written for this browser, for gaps the community lists leave —
    /// notably the mobile hosts of video sites, whose rules upstream only cover
    /// the desktop host.
    case appExtras = "app-extras"

    var fileName: String { rawValue }

    var displayName: String {
        switch self {
        case .easylist:          return "EasyList"
        case .easyprivacy:       return "EasyPrivacy"
        case .supplementalAds:     return "Supplemental Ads"
        case .mobileSpecific:      return "Mobile Web Rules"
        case .firstPartyTrackers:  return "First-Party Trackers"
        case .cnameTrackers:       return "CNAME Trackers"
        case .cookieNotices:       return "Cookie Notices"
        case .siteFixes:           return "Site Fixes"
        case .appExtras:           return "App Extras"
        }
    }

    /// The lowest blocking level that includes this list.
    var minimumLevel: BlockingLevel {
        switch self {
        case .easylist,                       // ads at every level above off
             .supplementalAds,
             .mobileSpecific,
             .siteFixes,                   // exceptions belong wherever rules do
             .appExtras:                   // our own gap-fillers, always on
            return .basic
        case .easyprivacy,                    // trackers from standard up
             .cnameTrackers:
            return .standard
        case .firstPartyTrackers:                // first-party only at the top level
            return .aggressive
        case .cookieNotices:             // any level, but only if asked for
            return .basic
        }
    }

    /// What the list does, in the one line Content Filtering has room for.
    var summary: String {
        switch self {
        case .easylist:
            return "The standard ad list. Blocks ad requests on most of the web."
        case .easyprivacy:
            return "Analytics, beacons and tracking pixels."
        case .supplementalAds:
            return "Extra rules for sites the general lists miss."
        case .mobileSpecific:
            return "Rules for mobile Safari and iOS web views specifically."
        case .firstPartyTrackers:
            return "Trackers a site serves from its own domain. Aggressive only."
        case .cnameTrackers:
            return "Hostnames that hide a tracker behind the site's own domain."
        case .siteFixes:
            return "Exceptions — puts back what the block lists break."
        case .appExtras:
            return "Rules written for this browser, mostly for mobile video sites."
        case .cookieNotices:
            return "Hides cookie-consent banners. Doesn't answer them for you."
        }
    }

    /// Whether this list is switched on right now, level aside.
    ///
    /// The cookie list keeps its own setting because it also has a switch in
    /// Privacy — one thing, one stored value, reachable from either screen.
    var isEnabled: Bool {
        switch self {
        case .cookieNotices: return Settings.blockCookieNotices
        default:                  return !Settings.disabledFilterLists.contains(rawValue)
        }
    }

    func setEnabled(_ enabled: Bool) {
        switch self {
        case .cookieNotices:
            Settings.blockCookieNotices = enabled
        default:
            var disabled = Settings.disabledFilterLists
            if enabled { disabled.remove(rawValue) } else { disabled.insert(rawValue) }
            Settings.disabledFilterLists = disabled
        }
    }

    /// Whether this list is also compiled into a `WKContentRuleList`.
    ///
    /// Converting a list to declarative rules is lossy, and lossy in the worst
    /// direction: exception (`@@`) rules mostly use options the declarative
    /// syntax can't express, so they are dropped while the block rules they were
    /// written to override survive. Measured against these lists, EasyList loses
    /// 72% of its exceptions and **EasyPrivacy loses 100% of them** — 54,732
    /// block rules with nothing left to hold them back.
    ///
    /// So EasyPrivacy is runtime-only, where the engine has every rule and every
    /// exception. Other blockers on this platform split the same way, and for
    /// the same reason.
    /// EasyList and the CNAME list are compiled. Every other list added since is
    /// either mostly exceptions (the site-fix lists), mostly cosmetic (the
    /// supplemental and cookie lists), or first-party rules that the
    /// declarative path exempts anyway — all of which convert badly or not at
    /// all. They run in the engine, where every rule and every exception is
    /// honoured.
    ///
    /// The CNAME list is the happy case for conversion: 16,800 bare host rules,
    /// no exceptions and almost no options, so nothing is lost on the way to
    /// declarative form.
    var usedDeclaratively: Bool {
        switch self {
        // Every list of *network* rules belongs here, not just EasyList.
        //
        // The runtime engine wraps `fetch` and `XMLHttpRequest` and nothing
        // else, so a rule that only reaches it cannot stop a `<script>` or an
        // `<iframe>` the page appends to the DOM — which is how ad networks
        // have loaded for years. Leaving these out meant most of the blocking
        // this app ships silently did not apply to the most common way an ad
        // arrives.
        case .easylist, .cnameTrackers, .supplementalAds, .mobileSpecific,
             .appExtras, .firstPartyTrackers:
            return true
        // Cosmetic and exception lists stay runtime-only. Converting those
        // produces `css-display-none` entries WebKit applies everywhere, which
        // is the wrong shape for rules written per-site.
        case .easyprivacy, .cookieNotices, .siteFixes:
            return false
        }
    }

    /// Whether the runtime engine loads this list too.
    ///
    /// The CNAME list doesn't need to be in both. Declarative rules already cover
    /// every request type, including the images and scripts the markup asks for
    /// that the runtime layer never sees, and parsing another 428 KB into the
    /// engine would buy nothing.
    var usedAtRuntime: Bool { self != .cnameTrackers }

    /// Whether the standard levels' first-party exemption applies to this list.
    ///
    /// It applies to every list but this one, and the exception is the entire
    /// point of the list. A CNAME-cloaked tracker is *served from the site's own
    /// domain* — `metrics.example.com` is first-party by every test the browser
    /// can make, and only the DNS answer, which we never see, gives it away. Left
    /// under the exemption these rules would match nothing below High, which is
    /// how this kind of tracker came to be worth setting up in the first place.
    ///
    /// Nothing else is safe to treat this way: the list is a hand-curated set of
    /// hostnames known to be trackers, not a pattern that might catch a site's
    /// own content.
    var exemptsFirstParty: Bool { self != .cnameTrackers }

    var bundleURL: URL? {
        Bundle.main.url(forResource: fileName, withExtension: "txt")
    }
}

/// Compiles filter lists into `WKContentRuleList`s and hands them to web views.
///
/// This is the primary blocking path, and it has to be: `WKNavigationDelegate`
/// only sees frame navigations, never the images, scripts and beacons that make
/// up almost every ad request. Declarative rules compiled into WebKit are the
/// only mechanism that sees those at all — WebKit does the blocking and the app
/// never learns which URLs a page requested, which is better for privacy than
/// intercepting them would be.
///
/// One rule list per source rather than one merged list: EasyList and
/// EasyPrivacy convert to roughly 82k and 56k rules, and WebKit caps a single
/// compiled list at around 150k. Merging them would sit a few thousand rules
/// below a hard failure.
///
/// An actor because compilation is slow and must not happen twice concurrently
/// for the same identifier.
actor ContentBlocker {

    static let shared = ContentBlocker()

    /// Bumped by hand when the compilation pipeline changes in a way that makes
    /// previously cached rule lists wrong. The list contents are covered by
    /// their own digest, so this is only for changes on our side.
    /// v2: cosmetic rules are no longer converted, so every previously cached
    /// rule list is wrong and must be recompiled.
    private static let pipelineVersion = 2

    /// `WKContentRuleListStore.default()` is main-actor isolated, so it can't be
    /// read from this actor's initialiser. Resolved on first use instead, which
    /// is inside an `async` call and can hop to the main actor properly.
    private var storeIfLoaded: WKContentRuleListStore?

    private var store: WKContentRuleListStore? {
        get async {
            if let storeIfLoaded { return storeIfLoaded }
            let resolved = await MainActor.run { WKContentRuleListStore.default() }
            storeIfLoaded = resolved
            return resolved
        }
    }

    /// In-memory cache. `WKContentRuleListStore` persists compiled lists across
    /// launches; this avoids even the lookup on repeat calls.
    private var compiled: [String: WKContentRuleList] = [:]

    /// Digests of the bundled list files, computed once per launch.
    private var digests: [FilterListSource: String] = [:]

    // MARK: - Public API

    /// Rule lists for a blocking level, compiling anything not already cached.
    ///
    /// Failures are logged and skipped rather than thrown: one list failing to
    /// compile should cost the user that list, not all blocking.
    func ruleLists(for level: BlockingLevel) async -> [WKContentRuleList] {
        guard level != .off else { return [] }

        var lists: [WKContentRuleList] = []
        for source in FilterListSource.allCases where includes(source, at: level) {
            do {
                lists.append(try await ruleList(for: source, level: level))
            } catch {
                print("[ContentBlocker] \(source.displayName) unavailable: \(error.localizedDescription)")
            }
        }
        return lists
    }

    /// Discard everything compiled — for a "clear cached rules" action, or after
    /// bundled lists are replaced.
    func reset() async {
        compiled.removeAll()
        guard let store = await store else { return }
        // `availableIdentifiers()` is `async` but not throwing; nothing here can
        // fail, so there is nothing to catch.
        let identifiers = await store.availableIdentifiers() ?? []
        for identifier in identifiers {
            try? await store.removeContentRuleList(forIdentifier: identifier)
        }
    }

    private func includes(_ source: FilterListSource, at level: BlockingLevel) -> Bool {
        guard source.usedDeclaratively, source.isEnabled else { return false }
        return level.includes(source.minimumLevel)
    }

    // MARK: - Compilation

    private func ruleList(for source: FilterListSource,
                          level: BlockingLevel) async throws -> WKContentRuleList {
        let identifier = try identifier(for: source, level: level)

        if let cached = compiled[identifier] { return cached }

        // Already compiled on a previous launch? Compiling is the expensive
        // step; the store keeps the bytecode on disk between launches.
        if let stored = try? await store?.contentRuleList(forIdentifier: identifier) {
            compiled[identifier] = stored
            return stored
        }

        let list = try await compile(source, level: level, identifier: identifier)
        compiled[identifier] = list
        return list
    }

    private func compile(_ source: FilterListSource,
                         level: BlockingLevel,
                         identifier: String) async throws -> WKContentRuleList {
        guard let url = source.bundleURL else {
            throw BlockerError.listMissing(source)
        }
        let text = try String(contentsOf: url, encoding: .utf8)

        // The Rust engine's most important job on iOS: filter syntax in,
        // Apple content-blocker JSON out. Off the main thread — it's tens of
        // milliseconds on a Mac and several times that on a phone.
        //
        // Network rules only. Converting cosmetic rules produces
        // `css-display-none` entries that WebKit applies to every site with no
        // way to honour the `#@#` unhide rules or `$generichide` exceptions that
        // are supposed to hold them back, which hides real page content. The
        // runtime engine applies the same rules correctly, scoped per URL.
        let converted = await Task.detached(priority: .userInitiated) {
            FilterEngine.contentBlockerRules(from: text, networkOnly: true)
        }.value

        guard let converted else { throw BlockerError.conversionFailed(source) }
        let json = exemptsFirstParty(source, at: level)
            ? exemptingFirstParty(converted) : converted

        guard let store = await store else { throw BlockerError.storeUnavailable }
        let list = try await store.compileContentRuleList(forIdentifier: identifier,
                                                          encodedContentRuleList: json)
        guard let list else { throw BlockerError.compilationReturnedNothing(source) }
        print("[ContentBlocker] compiled \(source.displayName) as \(identifier)")
        return list
    }

    /// Whether this list, at this level, leaves first-party requests alone.
    /// The level decides for every list but the CNAME one, which is exempt from
    /// the exemption — see `FilterListSource.exemptsFirstParty`.
    private func exemptsFirstParty(_ source: FilterListSource,
                                   at level: BlockingLevel) -> Bool {
        !level.blocksFirstParty && source.exemptsFirstParty
    }

    /// Append a rule that undoes every preceding rule for first-party loads.
    ///
    /// This is how a single converted ruleset serves both the standard and
    /// aggressive levels. `ignore-previous-rules`
    /// only affects rules before it, so it has to go last.
    ///
    /// Done with string surgery rather than `JSONSerialization`: the payload is
    /// several megabytes, we generated it ourselves, and re-parsing it just to
    /// add one element would cost far more than the append.
    private func exemptingFirstParty(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count > 2 else {
            // Empty or unexpected shape — leave it alone rather than corrupt it.
            return json
        }
        let exemption = """
        {"action":{"type":"ignore-previous-rules"},\
        "trigger":{"url-filter":".*","load-type":["first-party"]}}
        """
        return String(trimmed.dropLast()) + "," + exemption + "]"
    }

    // MARK: - Identity

    /// Identifier for a compiled list. It has to change whenever the compiled
    /// bytes would differ, or a stale list is served forever: the list contents
    /// (digest), the level (first-party exemption), the engine version (its
    /// converter output changes between releases), and our own pipeline version.
    private func identifier(for source: FilterListSource,
                            level: BlockingLevel) throws -> String {
        let digest = try digest(for: source)
        // Names what was actually compiled, not what the level is called: the
        // CNAME list is built without the exemption at every level, and two
        // different rulesets must never share an identifier.
        let scope = exemptsFirstParty(source, at: level) ? "standard" : "aggressive"
        return "\(source.rawValue).\(scope).\(digest).\(FilterEngine.version).v\(Self.pipelineVersion)"
    }

    private func digest(for source: FilterListSource) throws -> String {
        if let cached = digests[source] { return cached }
        guard let url = source.bundleURL else { throw BlockerError.listMissing(source) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        // Eight bytes is plenty to tell two versions of a list apart; this is a
        // cache key, not a security boundary.
        let hash = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        digests[source] = hash
        return hash
    }

    enum BlockerError: LocalizedError {
        case listMissing(FilterListSource)
        case conversionFailed(FilterListSource)
        case compilationReturnedNothing(FilterListSource)
        case storeUnavailable

        var errorDescription: String? {
            switch self {
            case .listMissing(let source):
                return "\(source.displayName) is not in the app bundle"
            case .conversionFailed(let source):
                return "\(source.displayName) could not be converted to content blocker rules"
            case .compilationReturnedNothing(let source):
                return "WebKit compiled \(source.displayName) to nothing"
            case .storeUnavailable:
                return "the content rule list store is unavailable"
            }
        }
    }
}

extension Notification.Name {
    /// The blocking level changed. `BrowserViewController` re-applies the rule
    /// lists when this fires.
    static let contentBlockingChanged = Notification.Name("TitleLess.contentBlockingChanged")
}

// MARK: - Applying to a web view

extension ContentBlocker {

    /// Swap the web view's rule lists to match a blocking level.
    ///
    /// Rule lists apply from the next navigation, so a level change shows up on
    /// the next page load rather than the current one — the same as every other
    /// content blocker on iOS.
    @MainActor
    static func apply(level: BlockingLevel, to webView: WKWebView) async {
        let lists = await shared.ruleLists(for: level)
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        for list in lists {
            controller.add(list)
        }
    }
}
