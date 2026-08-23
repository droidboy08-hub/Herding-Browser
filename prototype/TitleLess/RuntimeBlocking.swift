import CryptoKit
import Foundation
import WebKit

/// Owns the runtime filter engine — the second and third layers of blocking,
/// covering what compiled `WKContentRuleList`s structurally cannot.
///
/// Roughly half of every filter list converts to nothing declarative: cosmetic
/// rules (`##.ad-banner`), and network rules with options WebKit's rule syntax
/// can't express. Those only work if something evaluates them while the page is
/// running, which is what this engine does.
///
/// Built once, lazily, off the main thread, and cached to disk in the crate's
/// own serialized format so later launches skip parsing entirely.
actor AdblockEngineStore {

    static let shared = AdblockEngineStore()

    /// Everything that changes what an engine contains. Two requests with equal
    /// keys can share a build; anything else has to be a rebuild, or a settings
    /// change would leave the old rules in place until the app restarted.
    private struct BuildKey: Equatable {
        let level: BlockingLevel
        let sources: [FilterListSource]
        let customFilters: String
        /// Names the subscribed lists and when each was last fetched, so both
        /// toggling one and a refresh that brought new rules force a rebuild.
        let subscribedSignature: String
    }

    private var engine: FilterEngine?
    /// In-flight build. Several page loads can ask for the engine before it
    /// exists; they all await the same task rather than each starting a build.
    private var building: Task<FilterEngine?, Never>?
    /// What the current engine was built from, so a settings change rebuilds
    /// instead of silently serving the wrong rules.
    private var builtFor: BuildKey?

    private var cacheURL: URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("adblock-engine.dat")
    }

    // MARK: - Access

    /// The engine for the current blocking level, building it if necessary.
    /// Returns nil when blocking is off or the build failed.
    func engine(for level: BlockingLevel) async -> FilterEngine? {
        guard level != .off else { return nil }

        // The subscribed lists are main-actor state; read them here, once, rather
        // than hopping to the main actor from inside the build.
        let subscribed = await MainActor.run {
            (rules: CustomFilterListStore.shared.enabledRules(),
             signature: CustomFilterListStore.shared.signature)
        }
        let key = BuildKey(level: level,
                           sources: sources(for: level),
                           customFilters: Settings.customFilters,
                           subscribedSignature: subscribed.signature)
        if builtFor != key {
            // A settings change invalidates whatever is loaded or in flight.
            building?.cancel()
            building = nil
            engine = nil
            builtFor = key
            // Every cached verdict came from the engine being replaced.
            await VerdictCache.shared.invalidate()
        }
        if let engine { return engine }
        if let building { return await building.value }

        let task = Task<FilterEngine?, Never> { [key, cacheURL, rules = subscribed.rules] in
            await Self.build(sources: key.sources,
                             subscribed: rules,
                             custom: key.customFilters,
                             cacheURL: cacheURL)
        }
        building = task
        let built = await task.value
        // The settings can change while a build runs — the actor is free between
        // the suspension points. When they have, this engine is for a
        // configuration nobody is on any more, and publishing it would both hand
        // the *next* caller the wrong rules and drop the newer build's
        // registration. Hand it back to whoever asked for it and leave the
        // actor's state to the newer request.
        guard builtFor == key else { return built }
        engine = built
        building = nil
        return built
    }

    /// The scriptlet a URL needs, but only if the engine is already built.
    ///
    /// Deliberately never starts a build. This is called while a navigation is
    /// held open waiting for an answer, and blocking that on a first-launch parse
    /// would stall the page for as long as the parse takes. On the launch where
    /// the engine isn't ready yet, pages simply load without scriptlets.
    func readyScriptlet(for url: String) async -> String? {
        // `runsScriptlets` rather than `!= .off`: patching a page's own code is
        // the most invasive thing the blocker does, and `basic` is the level
        // that promises not to.
        guard Settings.blockingLevel.runsScriptlets, let engine else { return nil }
        guard let resources = await engine.cosmeticResources(for: url),
              !resources.injectedScript.isEmpty else { return nil }
        return resources.injectedScript
    }

    /// Throw away the engine and its disk cache — for a settings reset, or when
    /// the bundled lists are replaced.
    func invalidate() {
        building?.cancel()
        building = nil
        engine = nil
        builtFor = nil
        if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
        Task { await VerdictCache.shared.invalidate() }
    }

    private func sources(for level: BlockingLevel) -> [FilterListSource] {
        FilterListSource.allCases.filter {
            $0.usedAtRuntime && $0.isEnabled && level.includes($0.minimumLevel)
        }
    }

    // MARK: - Building

    /// Load from the serialized cache when it matches, otherwise parse the lists
    /// and write a fresh cache. `nonisolated static` so the work happens on a
    /// detached task rather than blocking the actor for the whole parse.
    private nonisolated static func build(sources: [FilterListSource],
                                          subscribed: [String],
                                          custom: String,
                                          cacheURL: URL?) async -> FilterEngine? {
        guard !sources.isEmpty else { return nil }

        return await Task.detached(priority: .utility) { () -> FilterEngine? in
            var texts: [String] = []
            for source in sources {
                guard let url = source.bundleURL,
                      let text = try? String(contentsOf: url, encoding: .utf8) else {
                    log("[Adblock] \(source.displayName) missing from the bundle")
                    continue
                }
                texts.append(text)
            }
            guard !texts.isEmpty else { return nil }
            // Subscribed lists after the bundled ones, and the user's own rules
            // after those.
            texts.append(contentsOf: subscribed)
            // The user's own rules go last, so an `@@` exception they wrote wins
            // over a block rule from a list.
            if !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                texts.append(custom)
            }

            let combined = texts.joined(separator: "\n")
            let stamp = Self.stamp(for: combined)

            // A cache from a different list version or crate version would
            // deserialize into rules that don't match what we think is loaded.
            if let cacheURL,
               let cached = try? Data(contentsOf: cacheURL),
               cached.count > stamp.count,
               cached.prefix(stamp.count) == stamp,
               let engine = FilterEngine(serialized: cached.dropFirst(stamp.count)) {
                // Serialization covers the filter data, not the scriptlets, so a
                // restored engine still needs them loaded.
                await Self.loadScriptlets(into: engine)
                log("[Adblock] engine restored from cache")
                return engine
            }

            // Trusted: every list here is one the app ships or the user chose
            // and can remove. Without it the `trusted-…` scriptlet rules — the
            // ones that strip ads out of a player's own response — are dropped
            // at parse time, silently.
            guard let engine = FilterEngine(rules: combined, trusted: true) else {
                log("[Adblock] engine failed to build")
                return nil
            }
            await Self.loadScriptlets(into: engine)
            log("[Adblock] engine built from \(texts.count) list(s)")

            if let cacheURL, let data = await engine.serialized() {
                try? (stamp + data).write(to: cacheURL, options: .atomic)
            }
            return engine
        }.value
    }

    /// Load the bundled scriptlets a `+js(...)` filter rule can inject.
    ///
    /// These are executable JavaScript, so they ship compiled into the app and
    /// are never fetched — that distinction is what App Store guideline 2.5.2
    /// turns on. The filter lists beside them are data and may be updated over
    /// the network; these may not.
    ///
    /// Two bundles are merged, because `useResources` replaces the engine's whole
    /// set rather than adding to it:
    ///
    /// * `scriptlets.json` — our own implementations, built from
    ///   `tools/scriptlets/*.js` by `tools/build-scriptlets.py`. These cover the
    ///   scriptlets the shipped filter lists actually name. They exist because
    ///   uBlock Origin's library, which those rules were written against, is
    ///   GPL-3.0 and cannot ship in an App Store binary; each one here is an
    ///   independent implementation of the documented behaviour.
    /// * `scriptlet-resources.json` — the upstream resource bundle credited in
    ///   Licences: MPL-2.0, with
    ///   individual scriptlets under MIT (mozilla/video-bg-play,
    ///   pixeltris/TwitchAdSolutions) and BSD. Verified free of GPL code. None of
    ///   the current lists reference these, but a list that does would otherwise
    ///   find nothing.
    private nonisolated static func loadScriptlets(into engine: FilterEngine) async {
        var merged: [Any] = []
        for name in ["scriptlets", "scriptlet-resources"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
                log("[Adblock] \(name).json missing or malformed")
                continue
            }
            merged.append(contentsOf: entries)
        }
        guard !merged.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: merged),
              let json = String(data: data, encoding: .utf8) else {
            log("[Adblock] no scriptlet resources to load")
            return
        }
        let loaded = await engine.useResources(json: json)
        log(loaded ? "[Adblock] \(merged.count) scriptlet resources loaded"
                     : "[Adblock] scriptlet resources rejected")
    }

    /// Fixed-width header identifying exactly what a cache file holds: a digest
    /// of the list text plus the crate version.
    private nonisolated static func stamp(for text: String) -> Data {
        let digest = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        // Padded to a constant length so the prefix can be compared without
        // parsing. `parseVersion` covers changes on our side that make a cached
        // engine wrong even though the rules and the crate are unchanged — v2 is
        // trusted parsing, without which a cache written before it would come
        // back missing every `trusted-…` rule.
        let value = "\(digest)|\(FilterEngine.version)|v2".padding(toLength: 48, withPad: " ",
                                                                   startingAt: 0)
        return Data(value.utf8)
    }
}

// MARK: - Party classification

enum RequestParty {

    /// Whether `url` is third-party relative to `sourceURL`.
    ///
    /// Only used to decide whether the standard level should leave a request
    /// alone — the engine applies filters' own `$third-party` options itself, and
    /// does so with a real public-suffix list. This is the coarser policy check
    /// on top, matching the first-party exemption the declarative rules get.
    ///
    /// The registrable domain is approximated as the last two labels, with the
    /// common three-label public suffixes handled explicitly. It errs toward
    /// calling things third-party, which means blocking slightly more in standard
    /// mode rather than letting an ad through.
    static func isThirdParty(url: URL, sourceURL: URL) -> Bool {
        guard let a = url.host, let b = sourceURL.host else { return true }
        return registrableDomain(a) != registrableDomain(b)
    }

    /// Second-level suffixes common enough to matter. Not exhaustive — a full
    /// public suffix list is thousands of entries and isn't worth shipping for a
    /// policy toggle.
    private static let multiPartSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "or.jp", "ne.jp",
        "com.au", "net.au", "org.au", "co.nz", "com.br", "com.cn", "com.mx",
        "co.in", "co.za", "co.kr", "com.tr", "com.sg", "com.hk",
    ]

    private static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let take = multiPartSuffixes.contains(lastTwo) ? 3 : 2
        return labels.suffix(take).joined(separator: ".")
    }
}

/// Recognises the "are you a human" checks that stand in front of a site.
///
/// These get an unconditional pass. A filter list can and does match parts of
/// them — a captcha is third-party script running on someone else's domain,
/// which is the shape of the thing lists are written to catch — but blocking one
/// costs the whole site rather than an advertisement. The same test exists in
/// the injected script, which is where most requests are decided; this is the
/// backstop for the ones that reach the native side.
///
/// Host *and* path where the host is shared: reCAPTCHA is served from
/// `www.google.com`, and exempting that host outright would exempt Google
/// Search along with it.
enum ChallengeSurface {

    static func contains(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path

        if host == "challenges.cloudflare.com" { return true }
        if host == "hcaptcha.com" || host.hasSuffix(".hcaptcha.com") { return true }
        // Cloudflare's managed challenge serves its scripts from the site's own
        // origin, so here the host says nothing and the path says everything.
        if path.hasPrefix("/cdn-cgi/challenge-platform/") { return true }
        if path.hasPrefix("/recaptcha/") && recaptchaHosts.contains(host) { return true }
        return false
    }

    private static let recaptchaHosts: Set<String> = [
        "www.google.com", "google.com", "www.gstatic.com",
        "recaptcha.net", "www.recaptcha.net",
    ]
}

// MARK: - Script message handlers

/// Answers the injected request-blocking script.
///
/// `WKScriptMessageHandlerWithReply` is what makes this possible at all: the
/// page's wrapped `fetch` gets a promise back, so it can wait for the verdict
/// before letting the real request go.
///
/// Retained strongly by `WKUserContentController`, which is fine — it holds no
/// reference back to any view controller.
final class RequestBlockingHandler: NSObject, WKScriptMessageHandlerWithReply {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              body["token"] as? String == WebViewFactory.securityToken,
              let resource = body["url"] as? String,
              let source = body["source"] as? String,
              let kind = body["type"] as? String,
              let resourceURL = URL(string: resource),
              let sourceURL = URL(string: source) else {
            // Anything malformed fails open. A page that can't be classified
            // must still load.
            replyHandler(false, nil)
            return
        }

        let level = Settings.blockingLevel
        guard level != .off else {
            replyHandler(false, nil)
            return
        }
        // A bot check or a captcha is never blocked, whatever the lists say and
        // whatever the level is. Blocking one doesn't hide an ad — it makes the
        // site behind it unreachable.
        guard !ChallengeSurface.contains(resourceURL) else {
            replyHandler(false, nil)
            return
        }
        // Standard levels leave first-party requests alone, the same exemption
        // the compiled rule lists carry.
        if !level.blocksFirstParty,
           !RequestParty.isThirdParty(url: resourceURL, sourceURL: sourceURL) {
            replyHandler(false, nil)
            return
        }

        let type = FilterResourceType(reportedName: kind)

        // Answer from the cache without leaving this thread when we can. On a
        // video site the same handful of hosts and paths are asked about
        // hundreds of times a minute — see `VerdictCache`.
        let key = VerdictCache.key(resource: resourceURL, type: type)
        if let cached = VerdictCache.shared.verdict(for: key) {
            replyHandler(cached, nil)
            return
        }

        // Detached, and deliberately not `@MainActor`.
        //
        // This ran on the main actor, which put every `fetch` and every
        // `XMLHttpRequest` from every frame into the same queue as the UI and
        // every WebKit callback — while the page's real request sat waiting on
        // the promise. A video player streams segments continuously and asks
        // for a burst of them on every seek and resume, so the main thread was
        // exactly where this work could least afford to be. That is the stall.
        Task.detached(priority: .userInitiated) {
            guard let engine = await AdblockEngineStore.shared.engine(for: level) else {
                replyHandler(false, nil)
                return
            }
            let blocked = await engine.matches(url: resource,
                                               sourceURL: source,
                                               resourceType: type)
            await VerdictCache.shared.store(blocked, for: key)
            replyHandler(blocked, nil)
        }
    }
}

/// Remembers what the engine said, so it is asked once rather than once per
/// request.
///
/// A streaming site fetches media segments from one host for the length of a
/// video, each with a different query string and the same verdict every time.
/// The query is dropped from the key for that reason: it is the part that
/// changes and the part filter rules least often depend on, so keying without
/// it collapses a whole video's segments onto a single lookup while leaving
/// host and path — where the rules actually match — intact.
///
/// An actor rather than a lock: entries are written from the detached tasks
/// above and read from the message handler's thread.
actor VerdictCache {

    static let shared = VerdictCache()

    /// Big enough for every host and path a page touches, small enough to be
    /// nothing. Cleared wholesale rather than aged — the cost of a miss is one
    /// engine call, so precision about *which* entry to drop earns nothing.
    private static let limit = 4096

    private var entries: [String: Bool] = [:]
    /// Read without awaiting, so the common case costs no hop at all. Kept in
    /// step with `entries` on every write.
    private nonisolated(unsafe) static var fastPath: [String: Bool] = [:]
    private static let fastPathLock = NSLock()

    static func key(resource: URL, type: FilterResourceType) -> String {
        var trimmed = URLComponents(url: resource, resolvingAgainstBaseURL: false)
        trimmed?.query = nil
        trimmed?.fragment = nil
        return "\(type.rawValue)|\(trimmed?.string ?? resource.absoluteString)"
    }

    /// The synchronous read. `nonisolated` and lock-guarded because the whole
    /// point is to answer without suspending — an `await` here would reintroduce
    /// the hop this cache exists to remove.
    nonisolated func verdict(for key: String) -> Bool? {
        Self.fastPathLock.lock()
        defer { Self.fastPathLock.unlock() }
        return Self.fastPath[key]
    }

    func store(_ blocked: Bool, for key: String) {
        if entries.count >= Self.limit {
            entries.removeAll(keepingCapacity: true)
            Self.fastPathLock.lock()
            Self.fastPath.removeAll(keepingCapacity: true)
            Self.fastPathLock.unlock()
        }
        entries[key] = blocked
        Self.fastPathLock.lock()
        Self.fastPath[key] = blocked
        Self.fastPathLock.unlock()
    }

    /// Everything the cache holds is an answer from one engine built for one
    /// level. Both change, and a stale verdict would outlive them.
    func invalidate() {
        entries.removeAll()
        Self.fastPathLock.lock()
        Self.fastPath.removeAll()
        Self.fastPathLock.unlock()
    }
}

/// Answers the injected cosmetic-filtering script: first the selectors specific
/// to the page's URL, then the generic ones matching the classes and ids the
/// page reports.
final class CosmeticFilterHandler: NSObject, WKScriptMessageHandlerWithReply {

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any],
              body["token"] as? String == WebViewFactory.securityToken,
              let kind = body["kind"] as? String else {
            replyHandler(nil, nil)
            return
        }

        let level = Settings.blockingLevel
        guard level != .off else {
            replyHandler(nil, nil)
            return
        }

        switch kind {
        case "page":
            guard let url = body["url"] as? String else {
                replyHandler(nil, nil)
                return
            }
            let webView = message.webView
            let frame = message.frameInfo
            Task { @MainActor in
                guard let engine = await AdblockEngineStore.shared.engine(for: level),
                      let resources = await engine.cosmeticResources(for: url) else {
                    replyHandler(nil, nil)
                    return
                }
                // Subframes only. The main frame gets its scriptlet as a
                // document-start user script, installed while the navigation was
                // still pending — see `BrowserViewController.installScriptlet`.
                // A subframe has no such moment: its URL isn't known until it
                // starts loading, and a user script can't be scoped to one frame.
                // So a cross-origin subframe gets its scriptlet here instead,
                // late, which is better than not at all.
                if !frame.isMainFrame, !resources.injectedScript.isEmpty {
                    webView?.evaluateJavaScript(resources.injectedScript,
                                                in: frame,
                                                in: .page) { result in
                        if case .failure(let error) = result {
                            log("[Adblock] scriptlet failed: \(error.localizedDescription)")
                        }
                    }
                }
                replyHandler([
                    // Site-specific selectors only run from `medium` up; `low`
                    // blocks requests and never touches the page's markup.
                    "hide": level.hidesElements ? Array(resources.hideSelectors) : [],
                    "exceptions": Array(resources.exceptions),
                    // `generichide` means the page has an exception against
                    // generic rules, so the script skips the second round trip.
                    // Below `high` the level itself is that exception — saying so
                    // here stops the script asking at all, rather than asking and
                    // being told nothing every time.
                    "generichide": resources.generichide || !level.hidesElementsGenerically,
                ], nil)
            }

        case "generic":
            // Generic rules match by class and id on every site there is, which
            // is how a page's own banner ends up hidden along with the ads. Only
            // `high` opts into that.
            guard level.hidesElementsGenerically else {
                replyHandler([], nil)
                return
            }
            let classes = body["classes"] as? [String] ?? []
            let ids = body["ids"] as? [String] ?? []
            let exceptions = Set(body["exceptions"] as? [String] ?? [])
            guard !classes.isEmpty || !ids.isEmpty else {
                replyHandler([], nil)
                return
            }
            Task { @MainActor in
                guard let engine = await AdblockEngineStore.shared.engine(for: level) else {
                    replyHandler([], nil)
                    return
                }
                let selectors = await engine.hiddenSelectors(classes: classes,
                                                             ids: ids,
                                                             exceptions: exceptions)
                replyHandler(selectors, nil)
            }

        default:
            replyHandler(nil, nil)
        }
    }
}
