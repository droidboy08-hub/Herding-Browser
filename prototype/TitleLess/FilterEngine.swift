import AdblockFFI
import Foundation

/// The kinds of request the engine can classify. The raw values are the strings
/// the Rust side expects, so nothing has to translate them again at the boundary.
enum FilterResourceType: String {
    case document
    case subdocument            // an iframe
    case script
    case stylesheet
    case image
    case media
    case font
    case xmlhttprequest         // covers both XHR and fetch
    case websocket
    case ping
    case other

    /// The engine's type for a name reported by the injected request hook.
    ///
    /// `fetch` is not a resource type in filter syntax — lists express both
    /// `fetch()` and `XMLHttpRequest` as `xmlhttprequest`, which is what the
    /// case above already claims to cover. It did not: the hook reports
    /// `"fetch"`, `init(rawValue:)` returned nil for it, and the caller's
    /// `?? .other` quietly turned every `fetch` into `other`.
    ///
    /// So every `$xmlhttprequest` rule missed every `fetch` — and since
    /// EasyPrivacy is runtime-only, that path is the only thing enforcing those
    /// rules at all. Modern pages reach for `fetch` far more often than XHR.
    init(reportedName: String) {
        if reportedName == "fetch" {
            self = .xmlhttprequest
        } else {
            self = FilterResourceType(rawValue: reportedName) ?? .other
        }
    }
}

/// Cosmetic filters for one page, decoded from the engine's JSON.
struct CosmeticResources: Decodable {
    /// Selectors to hide with `display: none !important`.
    let hideSelectors: Set<String>
    /// JSON-encoded filters whose behaviour needs in-page logic.
    let proceduralActions: Set<String>
    /// Class/id selectors that generic rules must not apply to.
    let exceptions: Set<String>
    /// Scriptlet JavaScript assembled from the bundled resources. Only ever
    /// comes from resources compiled into the app — downloading executable code
    /// is what App Store guideline 2.5.2 forbids.
    let injectedScript: String
    /// True when a `$generichide` exception applies, meaning the page should not
    /// be queried for additional generic rules.
    let generichide: Bool

    private enum CodingKeys: String, CodingKey {
        case hideSelectors = "hide_selectors"
        case proceduralActions = "procedural_actions"
        case exceptions
        case injectedScript = "injected_script"
        case generichide
    }

    var isEmpty: Bool {
        hideSelectors.isEmpty && proceduralActions.isEmpty && injectedScript.isEmpty
    }
}

/// Safe Swift face of the Rust `adblock` engine. Every `unsafe` pointer call in
/// the app lives in this file and nowhere else.
///
/// An actor for two independent reasons. The Rust engine does no locking of its
/// own, so concurrent calls into one handle would be a data race; and building an
/// engine parses megabytes of filter text, which must never happen on the main
/// thread. Actor isolation solves both.
actor FilterEngine {

    /// Opaque handle owned by Rust. Non-nil for the object's whole lifetime —
    /// the failable initialisers make sure a half-built engine never escapes.
    private let handle: OpaquePointer

    /// Version of the underlying crate. A serialized engine written by a
    /// different version won't load, so this doubles as a cache key.
    static var version: String {
        String(cString: adblock_engine_version())
    }

    // MARK: - Lifecycle

    /// Parse filter-list text. Slow — seconds for a full EasyList — which is
    /// exactly why this is behind an actor.
    ///
    /// - Parameter trusted: whether `trusted-…` scriptlet rules in this text are
    ///   allowed to run. They are dropped at parse time otherwise, and the drop
    ///   is silent — which matters more than it sounds, because the rules that
    ///   strip ads out of a video site's own player response are exactly those.
    ///   True for the lists this app ships or the user explicitly subscribed to;
    ///   those scriptlets can rewrite any response body, which is a capability
    ///   for a list you chose, not for every list on the internet.
    init?(rules: String, trusted: Bool = false) {
        guard let handle = rules.withCString({
            adblock_engine_create_with_trust($0, trusted)
        }) else {
            return nil
        }
        self.handle = handle
    }

    /// Reload a previously serialized engine. Milliseconds instead of seconds,
    /// so blocking is live on the first page load after launch rather than a few
    /// seconds in.
    init?(serialized data: Data) {
        let handle = data.withUnsafeBytes { buffer -> OpaquePointer? in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            // `uintptr_t` on the C side, so `UInt` here.
            return adblock_engine_create_from_serialized(base, UInt(buffer.count))
        }
        guard let handle else { return nil }
        self.handle = handle
    }

    deinit {
        // `deinit` is nonisolated, but by the time it runs nothing else can hold
        // a reference, so touching the handle here is safe.
        adblock_engine_free(handle)
    }

    // MARK: - Matching

    /// Whether the engine wants this request blocked. First/third-party is
    /// worked out inside the engine from the two URLs.
    func matches(url: String, sourceURL: String, resourceType: FilterResourceType) -> Bool {
        url.withCString { urlPtr in
            sourceURL.withCString { sourcePtr in
                resourceType.rawValue.withCString { typePtr in
                    adblock_engine_matches(handle, urlPtr, sourcePtr, typePtr)
                }
            }
        }
    }

    // MARK: - Cosmetic filtering

    /// Selectors and scriptlets that apply to a page. Returns nil when the
    /// engine has nothing for this URL or the payload can't be decoded.
    func cosmeticResources(for url: String) -> CosmeticResources? {
        guard let json = url.withCString({ adblock_engine_cosmetic_resources(handle, $0) }) else {
            return nil
        }
        // The buffer belongs to Rust; copy it out and hand it straight back.
        defer { adblock_string_free(json) }
        let string = String(cString: json)
        return try? JSONDecoder().decode(CosmeticResources.self, from: Data(string.utf8))
    }

    /// Generic cosmetic selectors for the classes and ids a page actually
    /// contains.
    ///
    /// Most of EasyList's cosmetic rules are generic — `##.ad-banner` with no
    /// domain — and `cosmeticResources(for:)` deliberately leaves them out;
    /// there are hundreds of thousands and only the ones whose class or id is on
    /// the page matter. The page reports what it has, this returns the subset
    /// that applies.
    func hiddenSelectors(classes: [String],
                         ids: [String],
                         exceptions: Set<String>) -> [String] {
        let encoder = JSONEncoder()
        func encode<T: Encodable>(_ value: T) -> String? {
            guard let data = try? encoder.encode(value) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        guard let classesJSON = encode(classes),
              let idsJSON = encode(ids),
              let exceptionsJSON = encode(exceptions) else {
            return []
        }
        let result = classesJSON.withCString { classesPtr in
            idsJSON.withCString { idsPtr in
                exceptionsJSON.withCString { exceptionsPtr in
                    adblock_engine_hidden_class_id_selectors(handle, classesPtr, idsPtr, exceptionsPtr)
                }
            }
        }
        guard let result else { return [] }
        defer { adblock_string_free(result) }
        let json = String(cString: result)
        return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    // MARK: - Serialization

    /// Snapshot the parsed engine so the next launch can skip parsing.
    func serialized() -> Data? {
        var length: UInt = 0
        guard let bytes = adblock_engine_serialize(handle, &length), length > 0 else {
            return nil
        }
        defer { adblock_bytes_free(bytes, length) }
        return Data(bytes: bytes, count: Int(length))
    }

    // MARK: - Content blocker conversion

    /// Convert filter-list text into Apple content-blocker JSON, ready for
    /// `WKContentRuleListStore`.
    ///
    /// Static because it builds and discards its own throwaway parser — it needs
    /// the debug-mode rule text the matching engine deliberately doesn't keep.
    ///
    /// `nonisolated` so callers can run it off the actor: it touches no shared
    /// state, and serialising every conversion behind one engine's actor would
    /// be a pointless bottleneck.
    nonisolated static func contentBlockerRules(from filterSet: String,
                                                networkOnly: Bool) -> String? {
        guard let json = filterSet.withCString({
            adblock_content_blocker_rules($0, networkOnly)
        }) else {
            return nil
        }
        defer { adblock_string_free(json) }
        return String(cString: json)
    }

    // MARK: - Scriptlet resources

    /// Load the scriptlets that `+js(...)` rules inject. Without these,
    /// `injectedScript` is always empty because the rule names a scriptlet the
    /// engine has no body for.
    @discardableResult
    func useResources(json: String) -> Bool {
        json.withCString { adblock_engine_use_resources(handle, $0) }
    }
}
