import Foundation

/// Search engines the user can pick in Settings.
enum SearchEngine: String, CaseIterable, Codable {
    case duckDuckGo, startpage, brave, google, bing, ecosia, yahoo

    var name: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .startpage:  return "Startpage"
        case .brave:      return "Brave"
        case .google:     return "Google"
        case .bing:       return "Bing"
        case .ecosia:     return "Ecosia"
        case .yahoo:      return "Yahoo"
        }
    }

    func url(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .startpage:  base = "https://www.startpage.com/sp/search"
        case .brave:      base = "https://search.brave.com/search"
        case .google:     base = "https://www.google.com/search"
        case .bing:       base = "https://www.bing.com/search"
        case .ecosia:     base = "https://www.ecosia.org/search"
        case .yahoo:      base = "https://search.yahoo.com/search"
        }
        var comps = URLComponents(string: base)
        comps?.queryItems = [URLQueryItem(name: "q", value: query)]
        return comps?.url
    }
}

/// Persisted app settings (UserDefaults). Only the flags backed by working
/// features are read by the app; the rest of the settings screen is stubbed.
enum Settings {
    private static let d = UserDefaults.standard

    private static func bool(_ key: String, default def: Bool) -> Bool {
        d.object(forKey: key) == nil ? def : d.bool(forKey: key)
    }

    // MARK: Downloads
    /// Re-run a download once, automatically, after it fails.
    static var autoRetryDownloads: Bool {
        get { bool("settings.autoRetryDownloads", default: true) }
        set { d.set(newValue, forKey: "settings.autoRetryDownloads") }
    }

    // MARK: Tabs
    /// Persist the user's choice of list vs grid view for tabs.
    ///
    /// Grid to begin with. A tab is recognised by what the page looked like far
    /// faster than by reading its title, and the grid is the view that shows
    /// that. The row of text is there for anyone who would rather scan names.
    static var tabsInGridView: Bool {
        get { bool("settings.tabsInGridView", default: true) }
        set { d.set(newValue, forKey: "settings.tabsInGridView") }
    }

    // MARK: Search & General
    static var searchEngine: SearchEngine {
        get { d.string(forKey: "settings.searchEngine").flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set { d.set(newValue.rawValue, forKey: "settings.searchEngine") }
    }

    /// Show kept sites under the search field in the start box.
    static var showFavourites: Bool {
        get { bool("settings.showFavourites", default: false) }
        set {
            d.set(newValue, forKey: "settings.showFavourites")
            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
        }
    }

    /// How far down the drag must travel to open Home.
    ///
    /// Was a slider, from 130pt at its least sensitive to 30pt at its most.
    /// This is the middle of that range and the value it shipped at — far
    /// enough clear of a stray finger to not fire by accident, short enough to
    /// not feel like work.
    static let revealSwipeDistance: CGFloat = 80

    /// Open the second box together with the start box, rather than waiting for
    /// one of the row's buttons to be tapped.
    ///
    /// It opens on whichever panel was last shown, so the box comes back the way
    /// it was left.
    static var startBoxShowsPanel: Bool {
        get { bool("settings.startBoxShowsPanel", default: true) }
        set { d.set(newValue, forKey: "settings.startBoxShowsPanel") }
    }

    /// How many buttons fit across the top of the start box.
    ///
    /// Not a preference — a measurement. The row shares its line with the
    /// "Where to?" title, and a fifth icon at a size worth tapping either
    /// crowds the title off the card or shrinks all of them below it.
    static let startBoxButtonCapacity = 4

    /// Which buttons sit in that row, in the order they appear.
    static var startBoxButtons: [StartBoxButton] {
        get {
            guard let raw = d.array(forKey: "settings.startBoxButtons") as? [String] else {
                return StartBoxButton.defaults
            }
            let stored = Self.deduplicated(raw.compactMap(StartBoxButton.init(rawValue:)))
            // An empty row is a row of nothing, and there would be no way back
            // out of it — a stored set that decodes to nothing means the
            // defaults, not a blank card.
            return stored.isEmpty ? StartBoxButton.defaults : stored
        }
        set {
            d.set(Self.deduplicated(newValue).map(\.rawValue), forKey: "settings.startBoxButtons")
            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
        }
    }

    /// First occurrence wins, and never more than the row holds. Applied on the
    /// way in *and* on the way out, so a defaults file edited by hand can't put
    /// the same icon in the row twice.
    private static func deduplicated(_ buttons: [StartBoxButton]) -> [StartBoxButton] {
        var seen = Set<StartBoxButton>()
        return Array(buttons.filter { seen.insert($0).inserted }.prefix(startBoxButtonCapacity))
    }

    /// What the browser shows when it opens.
    static var startPage: StartPage {
        get {
            d.string(forKey: "settings.startPage")
                .flatMap(StartPage.init(rawValue:)) ?? .startBox
        }
        set { d.set(newValue.rawValue, forKey: "settings.startPage") }
    }

    /// Let pages be pinched to zoom.
    ///
    /// Off by default, which is what the app has always done: the browser is
    /// driven by gestures on the page, and a pinch that zooms is a pinch that
    /// isn't available for anything else. On, it goes further than simply not
    /// disabling zoom — it overrides the sites that disable it themselves,
    /// which is the reason to want the switch at all.
    static var allowZoom: Bool {
        get { bool("settings.allowZoom", default: false) }
        set {
            d.set(newValue, forKey: "settings.allowZoom")
            NotificationCenter.default.post(name: .pageScriptsChanged, object: nil)
        }
    }

    /// Whether the one-time welcome has been shown.
    static var hasSeenWelcome: Bool {
        get { bool("settings.hasSeenWelcome", default: false) }
        set { d.set(newValue, forKey: "settings.hasSeenWelcome") }
    }

    /// Show a live preview of the destination above a link's menu.
    ///
    /// On by default, because a preview is the point of pressing a link you are
    /// unsure about. Off, the menu appears on its own — faster to read, and it
    /// loads nothing, which is the reason somebody would turn it off.
    static var showsLinkPreview: Bool {
        get { bool("settings.showsLinkPreview", default: true) }
        set { d.set(newValue, forKey: "settings.showsLinkPreview") }
    }

    /// Text that looks like a domain opens as a URL instead of a search.
    static var typedURLsOpenAsURLs: Bool {
        get { bool("settings.typedURLsAsURLs", default: true) }
        set { d.set(newValue, forKey: "settings.typedURLsAsURLs") }
    }

    // MARK: Privacy & Security
    /// Refuse every cross-site page a site tries to open, without asking.
    ///
    /// Off by default, and off does not mean *allowed* — it means the browser
    /// asks instead of deciding. That distinction is the whole of this setting.
    ///
    /// It used to be on, and the reasoning was sound as far as it went: a
    /// redirect ad works by being new — a domain nobody has listed yet,
    /// registered this morning, opened from inside your tap on something else —
    /// so a list-based blocker is always a step behind it, and a rule about
    /// *shape* rather than destination is not. What that reasoning missed is
    /// that `target="_blank"` has exactly the same shape. WebKit reports a
    /// tapped link that opens in a new tab and an ad spawning a window through
    /// one delegate call with nothing to tell them apart, so a site whose links
    /// all open in new tabs — a directory, an aggregator, a list of anything —
    /// had every link refused. The rule was right about pop-ups and wrong about
    /// how many ordinary things are pop-ups.
    ///
    /// Nobody else resolves this by blocking outright. Firefox shows a bar
    /// offering to show the blocked window or allow the site; Chrome puts an
    /// icon in the omnibox with the same two choices; Brave on iOS allows any
    /// pop-up the user touched the page to produce. All three refuse silently
    /// and then hand the decision back. This does the same, with the one action
    /// a phone has room for.
    ///
    /// On, it is the old behaviour exactly: refused, told, no way through.
    ///
    /// Pop-ups to the site's *own* domain are unaffected either way, and have
    /// to be: that is how a bank opens a statement, how card verification runs,
    /// and how a checkout hands off to its own payment page.
    static var blockRedirectPages: Bool {
        get { bool("settings.blockRedirectPages", default: false) }
        set { d.set(newValue, forKey: "settings.blockRedirectPages") }
    }

    /// Ask for Face ID, Touch ID or the passcode before entering private
    /// browsing.
    ///
    /// Guards the way *in*, not the way out. Leaving private browsing reveals
    /// nothing, and a lock on the exit would only be a lock on your own phone.
    ///
    /// On by default, which is the same call Safari makes. The cost of it being
    /// on when you didn't need it is one glance; the cost of it being off when
    /// you did is the whole point of the mode. It also costs nothing to find:
    /// the prompt is the first thing anyone sees on tapping Private, and the
    /// switch that turns it off is one screen away.
    ///
    /// A phone with no passcode set cannot honour this. Rather than sealing
    /// private browsing off on such a device, `BiometricGate` lets the request
    /// through and the settings row is hidden — see the reasoning there.
    static var requirePrivateAuth: Bool {
        get { bool("settings.requirePrivateAuth", default: true) }
        set { d.set(newValue, forKey: "settings.requirePrivateAuth") }
    }

    /// Upgrade http:// navigations to https://.
    static var httpsOnly: Bool {
        get { bool("settings.httpsOnly", default: false) }
        set { d.set(newValue, forKey: "settings.httpsOnly") }
    }

    // MARK: Playback
    /// Keep the page's media playing when the app is backgrounded — audio and
    /// video both.
    ///
    /// Two mechanisms, one switch, because they only work together. The audio
    /// session has to be claimed as `.playback` or iOS silences the app the
    /// moment it leaves the screen; and that alone still isn't enough for a
    /// video site, because those watch the Page Visibility API and pause
    /// themselves before the audio session ever matters. So this also injects
    /// the script that reports the page as visible and undoes those automatic
    /// pauses. Splitting them only ever produced a setting that looked on and
    /// did nothing.
    ///
    /// Off by default, and deliberately so. Apple has no rule against it —
    /// other browsers ship the same thing, likewise opt-in — but some video
    /// sites' terms of service do, so enabling it is the user's call and not a
    /// default.
    ///
    /// See `WebViewFactory.mediaBackgrounding`.
    static var backgroundPlayback: Bool {
        get {
            // Migration: the two old switches, of which the audio one used to
            // default on. Either being on means the user wanted background
            // playback, so carry that across rather than silently turning it
            // off under them.
            if d.object(forKey: "settings.backgroundPlayback") == nil {
                let legacyAudio = d.object(forKey: "settings.backgroundAudio") as? Bool
                let legacyVideo = d.object(forKey: "settings.backgroundVideoPlayback") as? Bool
                if legacyAudio != nil || legacyVideo != nil {
                    let merged = (legacyVideo ?? false) || (legacyAudio ?? false)
                    d.set(merged, forKey: "settings.backgroundPlayback")
                    return merged
                }
                return false
            }
            return d.bool(forKey: "settings.backgroundPlayback")
        }
        set { d.set(newValue, forKey: "settings.backgroundPlayback") }
    }

    // MARK: Appearance
    /// Which palette the app draws in.
    ///
    /// Three states rather than two, and a picker rather than a switch. A
    /// two-state "force dark" toggle could only ever read as off on a phone
    /// already in dark mode, which looked like a switch that didn't work. Naming
    /// all three choices says what each one does and leaves nothing to infer.
    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var name: String {
            switch self {
            case .system: return "System Default"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }
    }

    private static let appearanceModeKey = "settings.appearanceMode"

    static var appearanceMode: AppearanceMode {
        get {
            if let raw = d.string(forKey: appearanceModeKey),
               let mode = AppearanceMode(rawValue: raw) {
                return mode
            }
            // Follow the phone, unless told otherwise. Anyone upgrading from
            // the old "force dark" bool and who had it *on* keeps dark; having
            // it off always meant following the system, which is this.
            return d.bool(forKey: "settings.darkMode") ? .dark : .system
        }
        set {
            d.set(newValue.rawValue, forKey: appearanceModeKey)
            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
        }
    }

    /// Whether the downward swipe opens the start box — and, with it, what a
    /// tap on the address capsule does.
    ///
    /// One switch moving two bindings, which trade jobs rather than one of them
    /// going dark:
    ///
    /// |            | Swipe down      | Tap capsule       |
    /// |------------|-----------------|-------------------|
    /// | off        | Pull to refresh | Open the start box|
    /// | on         | Open the start box | Reload         |
    ///
    /// Both positions cover both functions. That is the whole point, and it is
    /// what the two-option picker this replaces got wrong: it asked *"should the
    /// swipe open Home?"*, and answering yes left reload with no gesture at all.
    /// The picker had to be neutral because there was nowhere else to put the
    /// loser; the capsule is that somewhere, so this can have an honest default.
    static var swipeOpensStartBox: Bool {
        get {
            // Carried over from the picker, so an existing choice survives.
            if d.object(forKey: "settings.swipeOpensStartBox") == nil,
               let legacy = d.string(forKey: "settings.swipeDownAction") {
                return legacy == "startBox"
            }
            return bool("settings.swipeOpensStartBox", default: false)
        }
        set { d.set(newValue, forKey: "settings.swipeOpensStartBox") }
    }

    /// Whether the current tab asked for the desktop version of a site.
    static var prefersDesktopSite: Bool {
        get { bool("settings.prefersDesktopSite", default: false) }
        set { d.set(newValue, forKey: "settings.prefersDesktopSite") }
    }

    /// Ask the player for the best quality the video offers, rather than
    /// letting it pick for the connection.
    ///
    /// Uses the player's own quality API — the same thing its quality menu
    /// does, just without having to open it on every video. What it can reach
    /// is still bounded by what the site offers this browser: a codec the web
    /// view can't decode is never in the list to begin with.
    static var preferHighestQuality: Bool {
        get { bool("settings.preferHighestQuality", default: false) }
        set { d.set(newValue, forKey: "settings.preferHighestQuality") }
    }

    /// Hide the bar a video site keeps pinned over the player as you scroll —
    /// the one carrying its logo, a search button and an "open the app" prompt.
    ///
    /// Purely a display preference: it hides chrome the site draws, not ads and
    /// not anything it needs to work. See `WebViewFactory.hideVideoTopBar`.
    static var hideVideoTopBar: Bool {
        get { bool("settings.hideVideoTopBar", default: false) }
        set { d.set(newValue, forKey: "settings.hideVideoTopBar") }
    }

    // MARK: Shields
    /// Hide cookie-consent banners, using the bundled list for them. Its own switch
    /// rather than part of the level: dismissing a consent dialog on the user's
    /// behalf is a choice about content, not about tracking.
    static var blockCookieNotices: Bool {
        get { bool("settings.blockCookieNotices", default: false) }
        set { d.set(newValue, forKey: "settings.blockCookieNotices") }
    }

    /// Make the APIs a fingerprinting script reads return something other than
    /// this device's real answers. See `WebViewFactory.fingerprintProtection`.
    static var blockFingerprinting: Bool {
        get { bool("settings.blockFingerprinting", default: true) }
        set { d.set(newValue, forKey: "settings.blockFingerprinting") }
    }

    /// Refuse to run any script a page brings with it. Off by default — it is a
    /// blunt instrument and half the web stops working — but it is the strongest
    /// single thing a browser can do about tracking.
    static var blockJavaScript: Bool {
        get { bool("settings.blockJavaScript", default: false) }
        set { d.set(newValue, forKey: "settings.blockJavaScript") }
    }

    /// The user's own filter rules, one per line, in ordinary filter-list syntax.
    /// Appended after the bundled lists when the engine is built.
    static var customFilters: String {
        get { d.string(forKey: "settings.customFilters") ?? "" }
        set { d.set(newValue, forKey: "settings.customFilters") }
    }

    /// Bundled lists the user switched off in Content Filtering, by raw value.
    ///
    /// Stored as the *exceptions* rather than the enabled set, so a list added in
    /// a later version arrives switched on without a migration.
    static var disabledFilterLists: Set<String> {
        get { Set(d.stringArray(forKey: "settings.disabledFilterLists") ?? []) }
        set { d.set(Array(newValue), forKey: "settings.disabledFilterLists") }
    }

    // MARK: Content blocking
    private static let blockingLevelKey = "settings.blockingLevel"

    /// How aggressively to block ads and trackers. See `BlockingLevel`.
    static var blockingLevel: BlockingLevel {
        get {
            guard let raw = d.string(forKey: blockingLevelKey) else { return .standard }
            if let level = BlockingLevel(rawValue: raw) { return level }
            // The levels used to be named for what they blocked (ads / standard
            // / aggressive). Map an old value onto its equivalent once, so an
            // update doesn't silently reset the user's choice to the default.
            let migrated = BlockingLevel.migrating(legacy: raw)
            d.set(migrated.rawValue, forKey: blockingLevelKey)
            return migrated
        }
        set { d.set(newValue.rawValue, forKey: blockingLevelKey) }
    }
}

extension Notification.Name {
    /// The interface style or the wallpaper changed.
    static let appearanceChanged = Notification.Name("TitleLess.appearanceChanged")
    /// The swipe-down binding moved, so the gesture and the capsule swap jobs.
    static let swipeBindingChanged = Notification.Name("TitleLess.swipeBindingChanged")
    /// Something changed that alters which scripts are injected into a page.
    /// The listener rebuilds the script set and reloads, because a viewport is
    /// applied while the document is loading and can't be revised afterwards.
    static let pageScriptsChanged = Notification.Name("TitleLess.pageScriptsChanged")
}

/// A button that can sit in the start box's top row.
///
/// There are more of these than there are slots, which is the point: the row is
/// the whole of this browser's chrome, so what goes in it is the one piece of
/// layout worth handing to the person using it.
enum StartBoxButton: String, CaseIterable, Codable {
    case tabs
    case downloads
    case history
    case bookmarks
    case settings

    /// What the row looks like out of the box: everything the browser had
    /// before the row was configurable.
    static let defaults: [StartBoxButton] = [.tabs, .downloads, .history, .settings]

    var name: String {
        switch self {
        case .tabs:      return "Tabs"
        case .downloads: return "Downloads"
        case .history:   return "History"
        case .bookmarks: return "Bookmarks"
        case .settings:  return "Settings"
        }
    }

    /// The symbol shown in the picker. Downloads and bookmarks draw themselves
    /// in the start box — this is only for the list, where a still glyph is
    /// what's wanted.
    var symbolName: String {
        switch self {
        case .tabs:      return "square.on.square"
        case .downloads: return "arrow.down.circle"
        case .history:   return "clock.arrow.circlepath"
        case .bookmarks: return "bookmark"
        case .settings:  return "gearshape"
        }
    }

    var detail: String {
        switch self {
        case .tabs:      return "Open pages, and the switch to private browsing."
        case .downloads: return "Files this browser has fetched."
        case .history:   return "Pages you have visited."
        case .bookmarks: return "Pages you have kept."
        case .settings:  return "This screen."
        }
    }
}

/// What the browser shows on launch.
enum StartPage: String, CaseIterable, Codable {
    /// The address box, with the last page restored behind it.
    case startBox
    /// Straight back to the page you were reading.
    case lastVisited

    var name: String {
        switch self {
        case .startBox:    return "Home"
        case .lastVisited: return "Last Page"
        }
    }
}

/// What a downward swipe on the page does.
enum SwipeDownAction: String, CaseIterable, Codable {
    /// Reveal the address box — the original behaviour, and the only way to
    /// reach tabs, history and settings.
    case startBox
    /// Reload the page, the way pull-to-refresh works everywhere else.
    case reloadPage

    var name: String {
        switch self {
        case .startBox:   return "Open Home"
        case .reloadPage: return "Reload Page"
        }
    }
}

/// The tiered blocking control: how much of the filter lists is allowed to act
/// on a page, from network requests only up to hiding elements by generic rules.
///
/// The levels differ along three axes, and they matter in this order:
///
/// * **Which lists** are loaded — ads only, or ads and trackers.
/// * **Whose requests** are matched — third-party only, or first-party too.
/// * **How much cosmetic filtering** runs. This is the axis that decides whether
///   a site looks broken. Rules written for a specific site (`example.com##.ad`)
///   are precise; *generic* rules (`##.banner`, `###promo`) match by class and id
///   on every site there is, and on a page whose own markup happens to use those
///   names they hide the site's own content. That is why generic rules are
///   confined to `high`.
/// The raw values are the persisted identity and stay as they are; the case
/// names follow what browsers actually call these tiers, so they are familiar.
enum BlockingLevel: String, CaseIterable, Codable {
    /// Nothing blocked beyond what WebKit's own tracking prevention does.
    case off
    /// Ad requests from third parties. No element hiding at all, so nothing a
    /// page draws itself can disappear — the level for a site that breaks.
    case basic = "low"
    /// Ads and trackers from third parties, plus element hiding by rules written
    /// for the site being visited. The default.
    case standard = "medium"
    /// Everything: first-party requests are matched too, and generic element
    /// hiding runs. Blocks the most and breaks the most.
    case aggressive = "high"

    var name: String {
        switch self {
        case .off:        return "Off"
        case .basic:      return "Basic"
        case .standard:   return "Standard"
        case .aggressive: return "Aggressive"
        }
    }

    /// What the level actually does, for the line under the control.
    var summary: String {
        switch self {
        case .off:
            return "Nothing is blocked."
        case .basic:
            return "Blocks third-party ad requests, and nothing else. Doesn't hide anything a site draws itself and doesn't touch a site's own code — use this if a site looks broken."
        case .standard:
            return "Blocks third-party ads and trackers, hides ad slots using rules written for the site you're on, and removes the ads video players build in. The default."
        case .aggressive:
            return "Also blocks first-party requests and hides elements by generic rules. Blocks the most, breaks the most."
        }
    }

    /// Ordering, so a filter list can name the lowest level that includes it
    /// without every call site restating the ladder.
    var rank: Int {
        switch self {
        case .off:        return 0
        case .basic:      return 1
        case .standard:   return 2
        case .aggressive: return 3
        }
    }

    func includes(_ level: BlockingLevel) -> Bool { rank >= level.rank }

    /// Whether first-party requests are matched. Everything below `aggressive`
    /// exempts them, which is where other blockers draw the line too.
    var blocksFirstParty: Bool { self == .aggressive }

    /// Whether element hiding runs at all. Off at `basic`: cosmetic rules are
    /// what make a page look wrong when they misfire, and `basic` exists for
    /// exactly the site where that happened.
    var hidesElements: Bool { self == .standard || self == .aggressive }

    /// Whether *generic* cosmetic rules — those matching any site by class or id —
    /// are applied.
    ///
    /// This was `aggressive` only, on the reasoning that a rule matching any
    /// site by class or id is the one that takes a site's own banner down with
    /// the ads. That is a real risk and it is not how anybody else draws the
    /// line. In Brave the standard and aggressive engines differ in exactly one
    /// thing — whether *first-party network requests* are blocked — and both
    /// run the class/id cosmetic pass; uBlock Origin applies generic cosmetic
    /// rules at its defaults too. Gating it here made Standard a level that
    /// blocked ad *requests* and then left the banners the site draws itself
    /// sitting on the page, which is the difference somebody notices
    /// immediately and reads as the blocker not working.
    ///
    /// The lists already carry the exception for sites this breaks: a
    /// `$generichide` rule turns the pass off per-site, and it is honoured.
    /// `basic` remains the level that touches no markup at all.
    var hidesElementsGenerically: Bool { self == .standard || self == .aggressive }

    /// Whether `+js(...)` scriptlets run.
    ///
    /// These used to run at every level above off, which is why the tiers were
    /// indistinguishable on the sites people actually judge a blocker by: a
    /// video site's ads are removed by scriptlets patching its player, not by
    /// blocking requests, so basic and aggressive produced the same result.
    ///
    /// They belong with element hiding rather than with request blocking. A
    /// scriptlet rewrites a page's own code — it is the most invasive thing
    /// here and the most likely to break a site, which is precisely what
    /// `basic` exists to avoid.
    var runsScriptlets: Bool { self == .standard || self == .aggressive }

    /// The levels were once named for what they blocked. Map an old stored value
    /// onto the tier that means the same thing.
    static func migrating(legacy raw: String) -> BlockingLevel {
        switch raw {
        case "ads":        return .basic
        case "standard":   return .standard
        case "aggressive": return .aggressive
        default:           return .standard
        }
    }
}
