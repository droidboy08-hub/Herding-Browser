import UIKit
import WebKit
import AVFoundation
import SafariServices

/// Minimal, tab-less browser surface.
/// - One WKWebView, no tabs, no toolbar buttons.
/// - A centered "start box" (URL/search entry) floats in the middle of the frame.
/// - Navigation is gesture-driven: edge-swipe = back/forward (WKWebView native),
///   swipe-down = reveal the start box to enter a new address.
final class BrowserViewController: UIViewController {

    private var webView: WKWebView!
    private let topBar = UIView()   // solid, adapts to the site color
    /// The only chrome shown over a page: which site you are on, and the way
    /// into the start box, the page menu and the other tabs. Replaces the round
    /// refresh button — reload is now pull-to-refresh. See `AddressCapsule`.
    private let addressCapsule = AddressCapsule()
    /// Whether this load has run long enough to be worth drawing. See
    /// `beginProgress` — a cached page finishing in 80ms would otherwise draw a
    /// flicker that reads as a glitch.
    private var progressDeserved = false
    private var progressTimer: Timer?
    /// Whether the start box was opened to edit this tab's address. See
    /// `revealHome(editingCurrentURL:)`.
    /// Whether the next address committed from the box opens a new tab.
    ///
    /// False is the common case and therefore the default: typing an address
    /// goes into the tab you are looking at. Only the two controls that say
    /// "new tab" — the + in the tab list and New Tab in the page menu — set it,
    /// and it is cleared the moment it is used or the box closes.
    ///
    /// It used to be the other way round: every route opened a new tab unless
    /// it opted out, so a control that forgot to set the flag inherited whatever
    /// the previous one left behind. The + forgot, which is why it stopped
    /// making tabs at all.
    private var nextSubmitOpensNewTab = false
    /// Set while a pop-up's web view is being adopted as a tab, so the
    /// selection callback does not load a page WebKit is already loading.
    private var adoptingPopup = false
    /// Sites the user has let through this session by tapping Open Anyway.
    ///
    /// Keyed on the site doing the opening, not on where it wants to go, which
    /// is how the same permission works in Chrome and Firefox: the answer being
    /// remembered is "this site may open windows", and a directory whose every
    /// link opens a new tab would otherwise ask again on every link — the exact
    /// complaint this whole change exists to fix.
    ///
    /// Held in memory and never written down. A permission granted in passing
    /// to get one link open should not still be granted next week, and a list
    /// of the sites somebody allowed pop-ups on is a browsing record like any
    /// other. Cleared with the profile, so nothing crosses into or out of
    /// private browsing.
    private var popupAllowedHosts: Set<String> = []
    private weak var popupNotice: UIView?
    private var popupNoticeDismissal: DispatchWorkItem?
    private var scrollObs: NSKeyValueObservation?
    private var zoomObs: NSKeyValueObservation?
    private var swipeBindingObserver: NSObjectProtocol?
    private var lastScrollY: CGFloat = 0
    /// The second window, while one is open. See `PopupWindowController`.
    private weak var popupWindow: PopupWindowController?
    /// A blocking change arrived while the start box was up; the page it
    /// applies to is behind the glass, so the reload waits for the box to go.
    private var reloadWhenOverlayCloses = false
    private var themeColorObs: NSKeyValueObservation?
    private var underPageObs: NSKeyValueObservation?
    private var currentTopColor: UIColor?
    private let homeOverlay = HomeOverlayView()
    private var progressObservation: NSKeyValueObservation?
    private var hasLoadedPage = false

    // Web content process crash recovery state. WebKit runs pages out of process;
    // that process can be killed under memory pressure (or jettisoned while we're
    // backgrounded). Reloading blindly risks an endless crash/reload loop, so
    // track attempts and defer recovery until we're actually on screen.
    private var contentProcessCrashes = 0
    private var needsReloadOnForeground = false
    private let maxCrashRecoveryAttempts = 2

    /// HTTP status of the main-frame response currently loading.
    ///
    /// An HTTP error is not a navigation failure: WebKit fetches 404s and 410s
    /// perfectly happily, `didFinish` fires, and nothing in the failure paths
    /// ever hears about it. When the server sends no body with the error — which
    /// expired links routinely do — the result is a correctly rendered empty
    /// document, i.e. a blank white page. Keeping the status lets `didFinish`
    /// tell that apart from a real page.
    private var lastMainFrameStatus: Int?
    private var foregroundObserver: NSObjectProtocol?
    private var documentPreview: UIDocumentInteractionController?

    // History recording state. A visit is logged when the navigation *commits*,
    // not when it finishes — that's what real browsers do, and it means a page
    // you abandon halfway still gets recorded.
    private var urlObservation: NSKeyValueObservation?
    /// What kind of navigation is in flight, decided in `decidePolicyFor` and
    /// consumed at commit.
    private var pendingTransition: VisitTransition = .link
    /// Set when the user submits the start box: WebKit reports those as `.other`,
    /// which is indistinguishable from a script-driven load without this.
    private var nextNavigationIsTyped = false
    /// A server redirect fired during the current provisional navigation.
    private var sawServerRedirect = false
    /// The URL of the document navigation currently in flight. The URL change it
    /// produces belongs to that navigation (recorded at commit), so the
    /// same-document paths ignore exactly that one — and nothing else, so a
    /// route change *during* a pending load still counts.
    private var pendingNavigationURL: URL?
    /// When the last visit was recorded, used to collapse the JS bridge and the
    /// KVO backstop seeing the same navigation.
    private var lastRecordedAt = Date.distantPast
    /// Whatever URL last committed — used to tell a same-document (pushState)
    /// change from a normal load.
    private var lastRecordedURL: URL?
    /// Pending re-read of the title after a same-document navigation.
    private var titleWatchdog: DispatchWorkItem?

    /// How long a restored session gets to put something on screen before it's
    /// treated as having come back blank. Long enough that a slow page isn't
    /// reloaded out from under itself.
    private let restoreVerificationDelay: TimeInterval = 2.5
    /// Identifies the current restore, so the check scheduled for a tab we've
    /// since left can't reload over the tab now on screen.
    private var restoreGeneration = 0
    private var restoreWatchdog: DispatchWorkItem?

    /// The two things a downward drag can do, only one of them live at a time.
    /// Held so the setting can switch between them without rebuilding the page.
    private var revealPan: UIPanGestureRecognizer?
    /// The drag already opened the start page; further movement in the same
    /// gesture must not open it again.
    private var revealPanFired = false
    /// How far below the safe area a downward swipe may start and still open the
    /// start box. Generous on purpose: there is no chrome marking the band, so a
    /// thin strip would be something to miss rather than something to aim at.
    private static let revealBandHeight: CGFloat = 200
    /// Whether the touch now on screen landed inside something the page scrolls
    /// itself. Reported by an injected `touchstart` handler — see
    /// `gestureRecognizerShouldBegin`, which is the only reader.
    private var touchIsOnScrollableElement = false
    /// Whether the touch that started landed inside a video player, reported by
    /// the same `touchstart` handler. A player is the one thing on a page that
    /// reliably wants downward drags of its own — scrubbing, minimising, the
    /// site's own dismiss gesture — and it is where this gesture was most in the
    /// way.
    private var touchIsOnMedia = false
    /// The page we have already tried to bring back from blank. A page that
    /// paints nothing twice is a page that is genuinely empty, and reloading it
    /// again would be a loop.
    private var blankRecoveryURL: URL?
    private var pullToRefresh: UIRefreshControl?
    /// Held rather than made on the spot: a generator has to warm the Taptic
    /// Engine before it can fire promptly, and one created at the moment of the
    /// gesture buzzes late enough to feel disconnected from it.
    ///
    /// `.heavy`, because this tick is the whole answer to the gesture — there is
    /// no button travel and nothing moves until the menu is already on screen,
    /// so a light tap under a fingertip resting on glass reads as nothing at all.
    private let menuFeedback = UIImpactFeedbackGenerator(style: .heavy)
    /// A tap is a lighter act than a press held until something happens, and the
    /// two should not feel the same — the weight is how you tell, without
    /// looking, which of them the button just registered.
    private let tapFeedback = UIImpactFeedbackGenerator(style: .medium)

    /// Everything this browser stores. Swapping in a private profile swaps the
    /// database, the session file and the website data store together.
    private var profile: Profile
    /// The profile the app launched with, kept so private browsing can be left
    /// again with its tabs and history intact.
    private let normalProfile: Profile
    /// Built the first time private browsing is entered, and kept for the rest of
    /// the process: leaving and re-entering keeps the private tabs, closing the
    /// app loses them. Nothing it holds is on disk — in-memory database,
    /// ephemeral tab store, non-persistent website data.
    private var privateProfile: Profile?
    /// Tabs live as a list in the start box; one web view is reused, so the
    /// manager holds URLs and session state rather than web views.
    private var tabManager: TabManager { profile.tabManager }
    private var tabs: [Tab] { tabManager.tabs }
    private var currentTabID: UUID? { tabManager.selectedTabID }
    private var backgroundObserver: NSObjectProtocol?
    /// Watches for media-settings changes so the injected scripts can be rebuilt
    /// without restarting the app.
    private var mediaSettingsObserver: NSObjectProtocol?
    private var pageScriptsObserver: NSObjectProtocol?
    /// Watches for blocking-level changes so the rule lists can be swapped.
    private var blockingObserver: NSObjectProtocol?
    /// Watches for dark-mode and wallpaper changes.
    private var appearanceObserver: NSObjectProtocol?
    private var favouritesObserver: NSObjectProtocol?
    /// The `+js(...)` scriptlet installed for the page currently loading, kept so
    /// a rebuild triggered by something else doesn't drop it.
    private var currentScriptlet: String?
    /// A scriptlet evaluated for a route change inside the current document.
    /// Tracked apart from `currentScriptlet` because it was run directly rather
    /// than installed as a user script — conflating the two would make the next
    /// real navigation think it was already in place. Cleared at each commit.
    private var sameDocumentScriptlet: String?

    /// Lock screen / Control Center transport controls, wired to the page's
    /// HTML5 media. See MediaControls.swift.
    let remoteMedia = RemoteMediaController()
    /// The web view, for the media controller's extension methods.
    var webViewForMediaControl: WKWebView? { webView }
    /// Favicon of the current tab — the only artwork we have for Now Playing.
    var currentTabIcon: UIImage? { tabManager.selectedTab?.icon }

    init(profile: Profile) {
        self.profile = profile
        normalProfile = profile
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupAddressCapsule()
        setupHomeOverlay()
        setupGestures()
        setupControlCenterAudioControls()
        observeMediaSettings()
        observeContentBlocking()
        observeForeground()
        observeBackgrounding()
        refreshSubscribedFilterLists()
        prewarmFilterEngine()
        observeAppearance()
        // An icon downloads after the favourite is added, so the row has to be
        // told when one lands.
        favouritesObserver = NotificationCenter.default.addObserver(
            forName: FavouritesStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.homeOverlay.reloadFavourites()
        }
        restoreSession()
    }

    /// Rebuild the injected scripts when a media setting is toggled, so turning
    /// background video playback on or off doesn't need an app restart. Scripts
    /// are injected per navigation, so the change lands on the next page load.
    private func observeMediaSettings() {
        mediaSettingsObserver = NotificationCenter.default.addObserver(
            forName: .mediaSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            WebViewFactory.installUserScripts(into: self.webView.configuration.userContentController,
                                              scriptlet: self.currentScriptlet)
            self.setupControlCenterAudioControls()
        }

        // Zoom, and anything else that decides what goes into a page. Unlike
        // the media scripts this one can't wait for the next navigation to be
        // useful: a viewport is settled while the document loads, so the page
        // in front of the user would keep the old one until they left it.
        pageScriptsObserver = NotificationCenter.default.addObserver(
            forName: .pageScriptsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            WebViewFactory.installUserScripts(into: webView.configuration.userContentController,
                                              scriptlet: currentScriptlet)
            guard hasLoadedPage, webView.url != nil else { return }
            webView.reload()
        }
    }

    /// Compile and attach the content blocking rule lists, and keep them in step
    /// with the setting.
    ///
    /// The first compile of a list takes a few seconds inside WebKit, so this
    /// deliberately doesn't block the first page load: rule lists apply from the
    /// next navigation anyway, and `WKContentRuleListStore` keeps the compiled
    /// bytecode, so every launch after the first attaches them immediately.
    private func observeContentBlocking() {
        applyContentBlocking()
        blockingObserver = NotificationCenter.default.addObserver(
            forName: .contentBlockingChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyContentBlocking(reloadingPage: true)
        }
    }

    /// Re-fetch subscribed filter lists that have gone stale. Off the critical
    /// path deliberately: the engine builds from whatever is already on disk, and
    /// a list that updates mid-session simply applies from the next build.
    private func refreshSubscribedFilterLists() {
        Task { @MainActor in
            // On a fresh install this is also where the catalogue's own defaults
            // are switched on for the first time.
            await CustomFilterListStore.shared.enableCatalogDefaultsIfNeeded()
            await CustomFilterListStore.shared.refreshStale()
        }
    }

    /// Keep the interface style and the wallpaper in step with their settings.
    ///
    /// The style is set on the *window*, not on this view controller: sheets and
    /// menus are presented into the window, and a controller-level override
    /// leaves them following the system while everything behind them doesn't.
    private func observeAppearance() {
        applyAppearance()
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .appearanceChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        // Set on the window, so it reaches the web view too and pages get the
        // `prefers-color-scheme` the app is drawing in.
        switch Settings.appearanceMode {
        case .system: view.window?.overrideUserInterfaceStyle = .unspecified
        case .light:  view.window?.overrideUserInterfaceStyle = .light
        case .dark:   view.window?.overrideUserInterfaceStyle = .dark
        }
        applyLegibilityOverWallpaper()
        applyTopColor()
        homeOverlay.reloadWallpaper()
        homeOverlay.reloadFavourites()
        homeOverlay.reloadStartBoxButtons()
        homeOverlay.panel.settingsChanged()
    }

    /// Let the wallpaper decide whether Home is drawn light or dark.
    ///
    /// The cards are clear glass, so what is behind them is what their text is
    /// read against — and the wallpaper is behind them, not the appearance
    /// setting. Dark mode with the Paper gradient put white labels on a cream
    /// card and made Home unreadable; the same would happen to anybody who
    /// picked a bright photo.
    ///
    /// This is the rule iOS uses on the Lock Screen, where the clock is dark on
    /// a bright wallpaper whatever the phone's appearance is set to. It applies
    /// to the overlay only. Everything reached *from* Home — Settings,
    /// Safeguards, the sheets — is presented over the page rather than over the
    /// wallpaper, and keeps the appearance the user chose.
    private func applyLegibilityOverWallpaper() {
        switch WallpaperStore.backdropIsLight {
        case true:  homeOverlay.overrideUserInterfaceStyle = .light
        case false: homeOverlay.overrideUserInterfaceStyle = .dark
        // The Default wallpaper is a dynamic colour: it is already whichever the
        // interface is, so there is nothing to override and following the
        // appearance is the correct answer rather than a fallback.
        case nil:   homeOverlay.overrideUserInterfaceStyle = .unspecified
        }
    }

    /// Show the welcome once, and only to somebody who has never used this app.
    ///
    /// The flag alone is not enough. A key that defaults to false is false for
    /// *everyone* the first time this version runs, so shipping it that way
    /// would greet existing users on update — which is the one audience that
    /// already knows the gestures.
    ///
    /// So an install with tabs or history behind it is treated as an upgrade
    /// and quietly marked as seen. Somebody who installed an earlier build and
    /// never opened a page will see it, which is the right answer anyway.
    private func presentWelcomeIfFirstRun() {
        guard !Settings.hasSeenWelcome else { return }

        let hasUsedTheAppBefore = !tabs.isEmpty || !profile.history.recentEntries().isEmpty
        guard !hasUsedTheAppBefore else {
            Settings.hasSeenWelcome = true
            return
        }

        let welcome = WelcomeViewController()
        // No swipe-to-dismiss: the button is what records it as seen, and a
        // screen dismissed around that would come back on the next launch.
        welcome.isModalInPresentation = true
        present(welcome, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentWelcomeIfFirstRun()
        // The window doesn't exist yet in `viewDidLoad`, so the style set there
        // lands on nothing.
        applyAppearance()
    }

    /// Start building the filter engine now, rather than on the first request
    /// that needs it.
    ///
    /// The engine is deliberately never built on demand from the navigation path
    /// — `readyScriptlet` returns nil rather than stalling a page load behind a
    /// parse. The consequence, without this, is that the first page after launch
    /// gets no scriptlets at all: on a video site that means the ads that only
    /// scriptlets can reach play through, and then don't on the next load, which
    /// is exactly what "it fails randomly" looks like from the outside.
    private func prewarmFilterEngine() {
        let level = Settings.blockingLevel
        guard level != .off else { return }
        Task.detached(priority: .utility) {
            _ = await AdblockEngineStore.shared.engine(for: level)
        }
    }

    /// - Parameter reloadingPage: whether to reload what's on screen.
    ///
    ///   Rule lists and injected scripts both take effect from the *next*
    ///   navigation, so without this a level change did nothing you could see:
    ///   you'd switch from Aggressive to Off on a page full of ads and the ads
    ///   would stay gone until you navigated. Every other browser reloads the
    ///   tab when its shields change, and this is why.
    ///
    ///   False at startup, where there is nothing loaded to reload and doing it
    ///   anyway would double every launch's first page load.
    private func applyContentBlocking(reloadingPage: Bool = false) {
        // The runtime scripts are only injected while blocking is on, so the
        // script set has to be rebuilt alongside the rule lists. Both take effect
        // from the next navigation.
        WebViewFactory.installUserScripts(into: webView.configuration.userContentController,
                                          scriptlet: currentScriptlet)
        // Whether pages may run scripts is a per-page preference, so unlike the
        // rest of this it applies to the *next* navigation only — the document
        // already parsed keeps whatever it was loaded with.
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript =
            !Settings.blockJavaScript
        Task { @MainActor [weak self] in
            guard let self else { return }
            await ContentBlocker.apply(level: Settings.blockingLevel, to: self.webView)
            // After the lists are attached, not before — a reload that races the
            // attach loads the page under the rules being replaced.
            guard reloadingPage, hasLoadedPage, webView.url != nil else { return }

            // Not while the start box is up. The level is changed *from* the
            // settings panel, so the page being reloaded is the one showing
            // through the glass behind it — you saw it blank and redraw under
            // the panel, which reads as something appearing behind the box
            // rather than as the page you're not looking at reloading. It is
            // held until the box closes, which is the moment it matters.
            guard homeOverlay.isHidden else {
                reloadWhenOverlayCloses = true
                return
            }
            webView.reload()
        }
        prewarmFilterEngine()
    }

    /// A content process jettisoned while we were backgrounded leaves the web
    /// view blank; `webViewWebContentProcessDidTerminate` defers the reload and
    /// we pick it up here, once the page is actually visible again.
    private func observeForeground() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Before the reload check, and outside it: the suspension has to be
            // lifted on every return to the foreground, not only on the returns
            // that happen to need a reload.
            self.resumePlaybackAfterForegrounding()
            guard self.needsReloadOnForeground else { return }
            self.needsReloadOnForeground = false
            // Deferred recovery isn't a crash-loop symptom, so it doesn't count
            // against the retry budget — reset it and reload once.
            self.contentProcessCrashes = 0
            guard self.hasLoadedPage else { return }
            log("[Nav] foreground — reloading page lost to a jettisoned content process")
            self.reloadCurrentPage()
        }
    }

    deinit {
        for observer in [foregroundObserver, backgroundObserver, mediaSettingsObserver,
                         pageScriptsObserver, blockingObserver, appearanceObserver,
                         favouritesObserver, swipeBindingObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Restore the persisted session; load the last-selected tab, else show the
    /// start box.
    private func restoreSession() {
        tabManager.delegate = self
        tabManager.restore()
        if let tab = tabManager.selectedTab {
            hasLoadedPage = true
            addressCapsule.show(url: webView.url)
            // The overlay starts out visible — that's the no-tabs launch state,
            // and its backdrop is opaque. Restoring a tab has to take it down, or
            // the restored page loads behind a white screen the user can't even
            // tap through: the dismiss gesture lives on the *blur* backdrop,
            // which is transparent until `present` runs, so nothing on screen
            // responds and the page they left is unreachable.
            // The tab is restored either way; the setting only decides whether
            // you land on it or on the address box with it waiting behind.
            if Settings.startPage == .startBox {
                showHome(animated: false)
            } else {
                homeOverlay.dismiss(animated: false)
            }
            load(tab)
        } else {
            showHome(animated: false)
        }
    }

    /// Put a tab back on screen. A stored `interactionState` restores its whole
    /// back/forward list; only a tab that never had one falls back to a plain
    /// URL load.
    private func load(_ tab: Tab) {
        restoreWatchdog?.cancel()
        restoreWatchdog = nil
        restoreGeneration += 1

        guard let state = tab.sessionState else {
            webView.load(pageRequest(tab.url))
            return
        }
        webView.interactionState = state
        // Restoring the blob is best-effort and reports nothing back — WebKit
        // accepts a state it can't do anything with just as happily as a good
        // one. If it didn't even leave a URL behind, there's nothing to wait for.
        guard webView.url != nil || webView.isLoading else {
            webView.load(pageRequest(tab.url))
            return
        }
        scheduleRestoreCheck(generation: restoreGeneration, fallback: tab.url)
    }

    /// A restored session can land on the right URL and still paint nothing: the
    /// back/forward list comes back, but the document it pointed at was served
    /// hours ago and no cached response is left to put on screen. Nothing
    /// *fails*, so no navigation delegate runs — the tab simply returns white.
    /// Check after the fact and reload if that's what happened.
    private func scheduleRestoreCheck(generation: Int, fallback: URL) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.restoreGeneration == generation else { return }
            self.recoverIfRestoreCameBackBlank(fallback: fallback, generation: generation)
        }
        restoreWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreVerificationDelay,
                                      execute: work)
    }

    private func recoverIfRestoreCameBackBlank(fallback: URL, generation: Int) {
        // A load still in flight is the restore working — leave it alone.
        guard !webView.isLoading else { return }

        // No web URL at all (nil, or the about:blank the failed restore left):
        // the session is worthless, go straight at the tab's stored address.
        guard let restored = webView.url, restored.isWebPage else {
            webView.load(pageRequest(fallback))
            return
        }
        webView.evaluateJavaScript(
            Self.paintedContentProbe
        ) { [weak self] result, _ in
            guard let self,
                  self.restoreGeneration == generation,
                  let visible = result as? Int, visible == 0,
                  // The page may have moved on while we were asking.
                  self.webView.url == restored else { return }
            log("[Nav] restored session painted nothing — reloading \(restored)")
            // Reload rather than load: the back/forward list restored fine and is
            // worth keeping, it's only this page's content that never arrived.
            // From origin, because the stale cache is what left it blank.
            if self.webView.backForwardList.currentItem != nil {
                self.webView.reloadFromOrigin()
            } else {
                self.webView.load(self.pageRequest(restored))
            }
        }
    }

    /// Capture the current tab's back/forward list before we navigate away from
    /// it, so returning to the tab returns to its history too.
    ///
    /// A web view sitting on about:blank — a restore that produced nothing, or a
    /// tab still being torn down — has a perfectly valid interaction state that
    /// restores to a blank page. Writing that over the tab's real session is how
    /// a tab loses its history permanently, so only real pages are stashed.
    private func stashSessionState() {
        guard let id = currentTabID, hasLoadedPage,
              webView.url?.isWebPage == true else { return }
        tabManager.setSessionState(webView.interactionState as? Data, for: id)
    }

    /// Page loads use a shorter timeout than the 60s default so a dead host
    /// surfaces an error quickly instead of appearing to hang.
    private func pageRequest(_ url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30)
    }

    /// Backgrounding is the last reliable moment before the system can kill us,
    /// so flush the session there.
    private func observeBackgrounding() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stopPlaybackIfBackgroundingDisallowed()
            self?.stashSessionState()
            self?.profile.shutdown()
        }
    }

    private func closeAllTabs() {
        tabManager.removeAllTabs()
        hasLoadedPage = false
        addressCapsule.isHidden = true
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let lum = currentTopColor?.luminance else { return .default }
        return lum > 0.6 ? .darkContent : .lightContent
    }

    /// Let the home indicator dim itself while a page is being read.
    ///
    /// It never disappears — the system fades it to a faint line after a moment
    /// of inactivity and brings it straight back on the next touch. That is the
    /// whole effect, and it is the same one Safari gets; there is no API that
    /// removes it outright.
    ///
    /// Only over a page. On the start box it stays at full strength, because
    /// that screen is a thing you are actively using rather than reading
    /// through, and a dimmed indicator there just looks broken.
    override var prefersHomeIndicatorAutoHidden: Bool {
        hasLoadedPage && homeOverlay.isHidden
    }

    // Background audio is claimed when media actually starts playing, not at
    // launch — see `RemoteMediaController.beginPlayback()` in MediaControls.swift.
    // Activating a `.playback` session here would stop whatever the user was
    // already listening to in another app the moment this one opened.

    // MARK: - Setup

    private func setupWebView() {
        installWebView()

        // Solid bar over the top safe area (status bar / Dynamic Island) that
        // adapts to the site color. Height tracks the safe-area top automatically.
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.backgroundColor = .systemBackground
        view.addSubview(topBar)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    /// Build the web view itself and put it in the view hierarchy.
    ///
    /// Separate from the chrome around it because the whole web view has to be
    /// replaced to switch profiles: a `WKWebsiteDataStore` is fixed when the
    /// configuration is created, so there is no way to move an existing web view
    /// onto private storage. Everything a web view owns — its process, its
    /// caches, its back/forward list — goes with it.
    /// - Parameter adopting: a web view to take over rather than create.
    ///
    ///   Used for pop-ups. `createWebViewWith` has to hand WebKit back a live
    ///   web view built from the configuration it supplied, so the window
    ///   cannot be made by the usual route — but once made it is an ordinary
    ///   page, and everything below applies to it unchanged.
    private func installWebView(adopting adopted: WKWebView? = nil) {
        if let adopted {
            webView = adopted
        } else {
            // Privacy defaults, injected scripts and the history bridge all live
            // in WebViewFactory — see WebViewConfiguration.swift.
            let config = WebViewFactory.makeConfiguration(profile: profile, scriptDelegate: self)
            webView = WKWebView(frame: view.bounds, configuration: config)
        }
        webView.frame = view.bounds
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true   // native edge-swipe = back/forward
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Retries start from the same web view, so they carry the page's cookies.
        DownloadManager.shared.webView = webView
        observeSameDocumentNavigations()
        // UIKit insets the content by the safe area, and the page scrolls
        // under the strip from there. This is left to UIKit deliberately.
        //
        // It was `.never` with the insets applied by hand, for the frosted bar
        // that used to live up there: a blur needs content underneath it at
        // rest, not only while scrolling. That bar is gone, and the hand-rolled
        // version cost more than it ever bought — UIKit does not move
        // `contentOffset` when `contentInset` changes, so every moment the
        // insets were recomputed was a chance to leave a page resting a safe
        // area too high, drawn under the Dynamic Island.
        //
        // Brave does not touch this either; its status-bar overlay is a plain
        // view over an otherwise ordinary web view.
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // Hard fallback: kill the scroll view's own pinch-zoom recognizer.
        applyZoomPolicy()
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // Full height, deliberately. Shortening the viewport to make room
            // for the capsule moves the *site's* own layout — its bottom bar
            // included — which is changing someone else's page to make room for
            // ours. The capsule goes lower instead.
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])


        progressObservation = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            self?.updateProgress(Float(wv.estimatedProgress))
        }
        // Tint the top bar to the site's theme color (falls back to the page's
        // under-page background color).
        themeColorObs = webView.observe(\.themeColor, options: [.initial, .new]) { [weak self] _, _ in
            self?.applyTopColor()
        }
        // Hide the capsule while reading forward, bring it back on the way up.
        //
        // KVO on the offset rather than the scroll view's delegate: that
        // delegate belongs to WebKit, and taking it is both unsupported and a
        // good way to break scrolling in ways that only show up on some pages.
        lastScrollY = webView.scrollView.contentOffset.y
        scrollObs = webView.scrollView.observe(\.contentOffset, options: [.new]) {
            [weak self] scrollView, _ in
            Task { @MainActor in self?.scrolled(scrollView) }
        }
        // WebKit re-derives the zoom limits whenever the viewport changes, which
        // on a single-page app is long after the load finished. Watching the
        // scale itself is the only way to catch every one of those.
        zoomObs = webView.scrollView.observe(\.zoomScale, options: [.new]) { scrollView, _ in
            Task { @MainActor in
                guard !Settings.allowZoom, scrollView.zoomScale != 1 else { return }
                scrollView.setZoomScale(1, animated: false)
            }
        }
        underPageObs = webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
            self?.applyTopColor()
        }
    }

    private func applyTopColor() {
        // Only a real page gets to colour the strip.
        //
        // On an internal state — no page yet, a failed restore sitting on
        // about:blank, an error page — the web view still reports *a* colour,
        // usually a stale one from the last site or a plain white that reads as
        // a bright bar in dark mode. Neither belongs to anything the user is
        // looking at, so those fall back to the app's own chrome colour. This
        // is the `isInternalPage` rule from the reference: internal → fallback.
        let onRealPage = hasLoadedPage && webView.url?.isWebPage == true
        let color = onRealPage
            ? (webView.themeColor ?? webView.underPageBackgroundColor)
            : nil
        currentTopColor = color

        // Set outright, never animated.
        //
        // This used to cross-fade over a quarter second, to smooth the sites
        // that change their theme colour as you scroll. That is a rare thing to
        // smooth, and the price was paid on every navigation: going back from a
        // dark page to a light one, you *watched* the strip travel from one to
        // the other, which is the one moment it should not be drawing attention
        // to itself. Safari does not animate it either — the change lands
        // between frames and the eye never catches it.
        topBar.backgroundColor = color ?? .systemBackground
        setNeedsStatusBarAppearanceUpdate()
    }

    /// The address capsule: bottom centre, over the page.
    ///
    /// Bottom *centre* and not bottom-trailing, where the round button sat. The
    /// trailing strip is where the forward-navigation edge swipe lives, and a
    /// left-swipe starting on a capsule pinned there would race it.
    private func setupAddressCapsule() {
        view.addSubview(addressCapsule)
        NSLayoutConstraint.activate([
            addressCapsule.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            // Below the safe area, not inside it.
            //
            // A site's own bottom bar sits at the bottom of the viewport, which
            // is the same strip the safe area occupies — so a capsule inside
            // the safe area lands on top of it. Dropping into the home-indicator
            // band puts ours under theirs without touching their layout, which
            // is the trade: the page keeps its full viewport, and the capsule
            // gives up the margin instead.
            addressCapsule.bottomAnchor.constraint(
                equalTo: view.bottomAnchor, constant: -18),
        ])
        addressCapsule.isHidden = true      // only meaningful once a page is loaded

        addressCapsule.onTap = { [weak self] in
            guard let self else { return }
            tapFeedback.impactOccurred()
            // Whichever of the two jobs the setting has left on the tap.
            if Settings.swipeOpensStartBox {
                // Bound to reload — and while a page is loading, to stopping it,
                // which is the only stop control the capsule has room for.
                if webView.isLoading { webView.stopLoading() } else { webView.reload() }
            } else {
                revealHome(editingCurrentURL: true)
            }
        }
        // Rebuilt every time it opens: the menu reflects the current settings
        // and disables what the current page can't do, so one captured once
        // would go stale the first time either changed.
        // The menu opening gets its own, heavier tick — the press has no other
        // confirmation until the menu actually appears.
        addressCapsule.onMenuOpen = { [weak self] in self?.menuFeedback.impactOccurred() }
        addressCapsule.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.pageMenu().children ?? [])
            }
        ])
        addressCapsule.onSwitchTab = { [weak self] step in
            self?.switchTab(by: step)
        }
    }

    /// Enforce the Zoom setting on the scroll view itself.
    ///
    /// The viewport meta is the polite half and is not enough on its own: a
    /// page can rewrite its own viewport at any moment, and WebKit re-reads the
    /// zoom limits on every navigation — so a recogniser disabled once at
    /// install is enabled again by the next page load. That is why pinch kept
    /// working with the switch off.
    ///
    /// Re-applied on every commit for exactly that reason.
    private func applyZoomPolicy() {
        guard webView != nil else { return }
        let allowed = Settings.allowZoom
        let scrollView = webView.scrollView
        scrollView.pinchGestureRecognizer?.isEnabled = allowed
        scrollView.bouncesZoom = allowed

        guard !allowed else {
            // Back to whatever the page asks for.
            scrollView.minimumZoomScale = 0.25
            scrollView.maximumZoomScale = 10
            return
        }
        // The clamp, because neither of the two polite mechanisms holds.
        //
        // `user-scalable=no` is advisory — WebKit re-derives the scale limits
        // from the viewport on every layout, and a page that rewrites its own
        // viewport wins the race. Disabling the pinch recogniser is undone the
        // same way. Pinning the scroll view's own limits is the one statement
        // of the rule the page has no say in.
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 1
        if scrollView.zoomScale != 1 { scrollView.setZoomScale(1, animated: false) }
    }

    /// Reserve room for the capsule, on top of what the device already asks for.
    ///
    /// The capsule hangs *below* the safe area (see `setupAddressCapsule`), so
    /// the page's own bottom inset does not clear it and the last of the page
    /// would sit underneath. This is the supported way to say so — UIKit adds it
    /// to the safe area, and the scroll view's own adjustment picks it up from
    /// there.
    ///
    /// Measured against the *window's* inset rather than the view's, because
    /// ours is added to the view's: reading that back would feed this into
    /// itself.
    private func updateAdditionalInsets() {
        let deviceBottom = view.window?.safeAreaInsets.bottom ?? 0
        let wanted = AddressCapsule.height + 16
        let extra = max(0, wanted - deviceBottom)
        guard abs(additionalSafeAreaInsets.bottom - extra) > 0.5 else { return }
        additionalSafeAreaInsets.bottom = extra
    }

    /// Scrolling down hides the capsule; scrolling up, or reaching the top,
    /// brings it back.
    ///
    /// The direction is not arbitrary — it is what Safari, Chrome and Firefox
    /// all do. Scrolling down means reading forward and wanting the content;
    /// scrolling up is already the gesture people associate with reaching for
    /// browser chrome.
    ///
    /// Deliberately *not* "reappears when scrolling stops". Pausing mid-page is
    /// ordinary reading, and a capsule sliding back over the text every time
    /// someone stops to read a paragraph is exactly the interruption this app
    /// exists to avoid.
    ///
    /// The cost, stated plainly: while hidden, the origin is not visible. That
    /// is acceptable — someone mid-scroll is reading, not deciding whether to
    /// trust who they are talking to — and one upward scroll brings it back.
    private func scrolled(_ scrollView: UIScrollView) {
        guard !addressCapsule.isHidden else { return }
        let y = scrollView.contentOffset.y
        defer { lastScrollY = y }

        // At the top, always shown, whatever the last direction was.
        if y <= -scrollView.adjustedContentInset.top + 1 {
            addressCapsule.setConcealed(false)
            return
        }
        // Rubber-banding past the bottom reverses the offset without the reader
        // having changed direction, so it is not a signal.
        guard y < scrollView.contentSize.height - scrollView.bounds.height else { return }

        // A threshold, so a thumb resting on a page doesn't flicker it in and out.
        let moved = y - lastScrollY
        guard abs(moved) > 6 else { return }
        addressCapsule.setConcealed(moved > 0)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateAdditionalInsets()
    }


    // MARK: - Long-press build-up

    // MARK: - Page menu

    /// Everything the browser can do to the page you're on.
    ///
    /// It hangs off the refresh button because that button is the only chrome
    /// on screen — there is no toolbar to put a menu button in, and inventing
    /// one would cost the thing that makes this browser what it is.
    private func pageMenu() -> UIMenu {
        let hasPage = hasLoadedPage && webView.url?.isWebPage == true

        // What the swipe does, at the top, as a switch showing its state. The
        // subtitle names what the *other* surface gets, because the setting
        // moves two bindings and its title can only name one.
        let opensHome = Settings.swipeOpensStartBox
        let gesture = UIAction(
            title: "Open Home by Swiping Down",
            subtitle: opensHome ? "The capsule reloads" : "The capsule opens Home",
            state: opensHome ? .on : .off
        ) { [weak self] _ in
            Settings.swipeOpensStartBox = !opensHome
            self?.configureSwipeDownBehaviour()
        }

        let desktop = UIAction(
            title: "Desktop Site",
            image: UIImage(systemName: "desktopcomputer"),
            state: Settings.prefersDesktopSite ? .on : .off
        ) { [weak self] _ in
            self?.setDesktopSite(!Settings.prefersDesktopSite)
        }
        desktop.attributes = hasPage ? [] : .disabled

        let share = UIAction(title: "Share",
                             image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            self?.shareCurrentPage()
        }
        share.attributes = hasPage ? [] : .disabled

        // Add and remove are one item, showing which of the two this tap would
        // do — the same star every browser has, and the reason a bookmark never
        // needs a second screen to create.
        let kept = webView.url.map { BookmarkStore.shared.contains($0) } ?? false
        let keep = UIAction(
            title: kept ? "Remove Bookmark" : "Add Bookmark",
            // Our own ribbon rather than an SF Symbol, drawn from the same path
            // the animated view uses — filled once the page is kept, so the row
            // says which of the two things the tap will do before you read it.
            image: kept ? BookmarkIconView.filledImage() : BookmarkIconView.image()
        ) { [weak self] _ in
            self?.toggleBookmark()
        }
        keep.attributes = hasPage ? [] : .disabled

        let bookmarks = UIAction(title: "Bookmarks",
                                 image: UIImage(systemName: "book")) { [weak self] _ in
            self?.presentBookmarks()
        }

        let printPage = UIAction(title: "Print",
                                 image: UIImage(systemName: "printer")) { [weak self] _ in
            self?.printCurrentPage()
        }
        printPage.attributes = hasPage ? [] : .disabled

        // A new tab is the start box: this browser has no blank page to put in
        // one, and a tab exists from the moment an address is entered. So the
        // action that starts a tab and the action that opens the box are the
        // same action, named for what you are trying to do rather than for the
        // panel it puts on screen.
        let newTab = UIAction(title: "New Tab",
                              image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
            guard let self else { return }
            nextSubmitOpensNewTab = true
            revealHome()
        }

        let downloads = UIAction(title: "Downloads",
                                 image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
            guard let self else { return }
            revealHome()
            homeOverlay.showDownloads()
        }

        // Always here, not only when the gear has been traded out of the start
        // box row: this is the menu the page has, and settings is somewhere you
        // want to get to from a page without going by way of the box.
        let settings = UIAction(title: "Settings",
                                image: UIImage(systemName: "gearshape")) { [weak self] _ in
            guard let self else { return }
            revealHome()
            homeOverlay.showSettings()
        }

        // Written top-down, as it appears on screen, and reversed once on the
        // way out.
        //
        // The button is pinned to the bottom of the screen, so the menu always
        // opens upward — and UIKit lays an upward menu out from its anchor,
        // which puts the first element nearest the thumb and therefore at the
        // bottom. Writing the groups in the order they are read and flipping
        // here beats writing them backwards and remembering why.
        let groups: [[UIMenuElement]] = [
            [newTab],
            [desktop, share, keep, bookmarks, printPage],
            [downloads, settings],
            [gesture],
        ]
        return UIMenu(children: groups.reversed().map {
            UIMenu(options: .displayInline, children: $0.reversed())
        })
    }

    /// Ask for the desktop layout of the current site.
    ///
    /// Two halves, and both are needed: the content mode is what WebKit passes
    /// to the site's own media queries, and the user agent is what a server
    /// looks at before it has rendered anything. Sites pick whichever they
    /// trust, so a browser that sets only one gets the mobile page from half
    /// the web.
    private func setDesktopSite(_ desktop: Bool) {
        Settings.prefersDesktopSite = desktop
        webView.configuration.defaultWebpagePreferences.preferredContentMode =
            desktop ? .desktop : .recommended
        webView.customUserAgent = desktop ? Self.desktopUserAgent : nil
        // The third half of it, and the one that was missing: the injected
        // viewport. Without this the page keeps `width=device-width` and lays
        // the desktop stylesheet out in a phone's width, which is neither one
        // thing nor the other.
        WebViewFactory.installUserScripts(into: webView.configuration.userContentController,
                                          scriptlet: currentScriptlet)
        // From origin: the mobile page is in the cache and a plain reload would
        // hand it straight back.
        webView.reloadFromOrigin()
    }

    /// Safari on macOS. A site that sniffs the agent has to see a desktop
    /// browser, and this is the one every iOS browser presents for the purpose.
    private static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func shareCurrentPage() {
        guard let url = webView.url, url.isWebPage else { return }
        let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Required on iPad, harmless on iPhone.
        share.popoverPresentationController?.sourceView = addressCapsule
        share.popoverPresentationController?.sourceRect = addressCapsule.bounds
        present(share, animated: true)
    }

    /// The two ways a favourite gets added.
    ///
    /// Adding the page you're on is the common one, so it's first and it's one
    /// tap. Typing an address covers the rest — a site you want kept before you
    /// have been there, which a browser shouldn't make you visit first.
    private func addFavourite() {
        guard !FavouritesStore.shared.isFull else {
            report(title: "No room left",
                   message: "Hold a favourite to remove it, then add this one.")
            return
        }

        let sheet = UIAlertController(title: "Add Favourite", message: nil,
                                      preferredStyle: .actionSheet)
        if let url = webView.url, url.isWebPage, hasLoadedPage {
            sheet.addAction(UIAlertAction(title: "Add Current Page", style: .default) { [weak self] _ in
                self?.addCurrentPageToFavourites()
            })
        }
        sheet.addAction(UIAlertAction(title: "Enter Address…", style: .default) { [weak self] _ in
            self?.promptForFavouriteAddress()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        // Required on iPad, ignored on iPhone.
        sheet.popoverPresentationController?.sourceView = homeOverlay.favourites
        sheet.popoverPresentationController?.sourceRect = homeOverlay.favourites.bounds
        present(sheet, animated: true)
    }

    private func addCurrentPageToFavourites() {
        guard let url = webView.url, url.isWebPage else { return }
        let title = webView.title ?? ""
        // Ask the page what its icons are before adding it. A site that names
        // its own icon beats any guess at a conventional path, and this is the
        // only moment the page is open to be asked.
        harvestIconURLs { [weak self] hints in
            guard let self else { return }
            let added = FavouritesStore.shared.add(url: url, title: title, iconHints: hints)
            UINotificationFeedbackGenerator().notificationOccurred(added ? .success : .warning)
            homeOverlay.reloadFavourites()
        }
    }

    private func promptForFavouriteAddress() {
        let alert = UIAlertController(
            title: "Add Favourite",
            message: "Enter a site address.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "example.com"
            field.keyboardType = .URL
            field.textContentType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            // Through the same parser the address box uses, so "example.com"
            // and "https://example.com/x" both land where you'd expect — and a
            // search phrase doesn't quietly become a favourite.
            guard case .url(let url)? = URLResolver.parse(text) else {
                report(title: "That isn't an address",
                       message: "Enter a site address, like example.com.")
                return
            }
            let added = FavouritesStore.shared.add(url: url, title: url.host ?? text)
            UINotificationFeedbackGenerator().notificationOccurred(added ? .success : .warning)
            homeOverlay.reloadFavourites()
        })
        present(alert, animated: true)
    }

    /// Every icon the current page declares, largest first.
    ///
    /// Reads the `<link rel="apple-touch-icon">` family and the web-app
    /// manifest, which is where a modern site puts its 192 and 512 pixel icons.
    private func harvestIconURLs(completion: @escaping ([URL]) -> Void) {
        let script = """
        (function() {
          var out = [];
          function push(href, size) {
            if (!href) { return; }
            try { out.push({ url: new URL(href, location.href).href, size: size || 0 }); }
            catch (e) {}
          }
          var links = document.querySelectorAll(
            "link[rel~='apple-touch-icon'],link[rel~='apple-touch-icon-precomposed']," +
            "link[rel~='icon'],link[rel~='shortcut']");
          for (var i = 0; i < links.length; i++) {
            var sizes = links[i].getAttribute('sizes') || '';
            var largest = 0;
            sizes.split(/\\s+/).forEach(function(pair) {
              var side = parseInt(pair.split(/x/i)[0], 10);
              if (!isNaN(side) && side > largest) { largest = side; }
            });
            // An apple-touch-icon with no declared size is 180 by convention.
            push(links[i].href, largest || (links[i].rel.indexOf('apple') !== -1 ? 180 : 0));
          }
          var manifest = document.querySelector("link[rel='manifest']");
          if (manifest) { push(manifest.href, -1); }   // marked, fetched natively
          out.sort(function(a, b) { return b.size - a.size; });
          return JSON.stringify(out);
        })()
        """
        webView.evaluateJavaScript(script) { result, _ in
            guard let json = result as? String,
                  let data = json.data(using: .utf8),
                  let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                completion([])
                return
            }
            let urls = entries.compactMap { entry -> URL? in
                guard let text = entry["url"] as? String else { return nil }
                return URL(string: text)
            }
            completion(urls)
        }
    }

    private func report(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Keep the current page, or drop it if it's already kept.
    ///
    /// Confirmed by feel rather than by a banner: there is nowhere on screen to
    /// put one, and a page you just kept is a page you are still reading.
    private func toggleBookmark() {
        guard let url = webView.url, url.isWebPage else { return }
        let added = BookmarkStore.shared.toggle(url: url, title: webView.title ?? "")
        UINotificationFeedbackGenerator().notificationOccurred(added ? .success : .warning)
        showBookmarkFlourish(added: added)
    }

    /// The ribbon, squashing once over the middle of the page, then gone.
    ///
    /// A bookmark taken from a menu has nothing to show for itself — the menu
    /// closes and the page looks exactly as it did. This is the receipt: filled
    /// when the page was kept, outlined when it was dropped, on screen just long
    /// enough to read and never long enough to be in the way.
    private func showBookmarkFlourish(added: Bool) {
        let icon = BookmarkIconView(size: 64, strokeWidth: 3)
        icon.isUserInteractionEnabled = false
        icon.tintColor = .label
        icon.translatesAutoresizingMaskIntoConstraints = false

        let plate = GlassSurface.makeView(radius: 28, fallback: .systemThickMaterial)
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.alpha = 0
        plate.contentView.addSubview(icon)
        view.addSubview(plate)

        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            plate.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            plate.widthAnchor.constraint(equalToConstant: 120),
            plate.heightAnchor.constraint(equalToConstant: 120),
            icon.centerXAnchor.constraint(equalTo: plate.contentView.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: plate.contentView.centerYAnchor),
        ])

        icon.isFilled = added
        UIView.animate(withDuration: 0.16) { plate.alpha = 1 } completion: { _ in
            icon.playOnce()
        }
        UIView.animate(withDuration: 0.25, delay: 0.7, options: [.curveEaseIn]) {
            plate.alpha = 0
        } completion: { _ in
            plate.removeFromSuperview()
        }
    }

    /// Hosts that exist to sign you in to somewhere else.
    ///
    /// Matched on the registrable domain, so `accounts.google.com` and
    /// `oauth2.googleapis.com` both count and `google.com.evil.example` does
    /// not. Kept deliberately short: every entry is a domain an attacker would
    /// have to *own* to abuse, which is what makes an allow-list safe here
    /// where a block-list of ad domains is not.
    private static let signInDomains: Set<String> = [
        "google.com", "googleapis.com", "gstatic.com",   // Google / Firebase
        "apple.com",                                     // Sign in with Apple
        "microsoftonline.com", "live.com", "microsoft.com",
        "github.com", "gitlab.com", "bitbucket.org",
        "facebook.com", "twitter.com", "x.com", "linkedin.com",
        "okta.com", "auth0.com", "duosecurity.com", "onelogin.com",
        "amazon.com", "amazoncognito.com",
        "slack.com", "atlassian.com", "notion.so", "figma.com",
        "paypal.com", "stripe.com",                      // and paying
        "id.me", "login.gov",
    ]

    private static func isSignInProvider(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return false }
        // Two labels, and three for the handful of `co.uk`-style suffixes the
        // party check already knows about.
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if signInDomains.contains(lastTwo) { return true }
        guard labels.count >= 3 else { return false }
        return signInDomains.contains(labels.suffix(3).joined(separator: "."))
    }

    /// Open a support destination: a page of ours, or a pre-addressed mail.
    ///
    /// Reached from two places now — the Website row on the About card, and the
    /// three rows behind Support — so it is a method rather than a closure.
    private func openSupport(_ destination: SupportDestination) {
        switch destination {
        // The pages are sheets rather than tabs.
        //
        // Opened as a tab, they were the tab's only history entry, so the back
        // swipe had nowhere to go and left a blank white page behind. It also
        // put a page nobody chose to browse into the tab list, and left the
        // reader to find their own way back. A Safari sheet has its own chrome,
        // its own Done button, and no way to strand anybody.
        case .website:
            presentSheet(SupportInfo.websiteURL)
        case .help:
            presentSheet(SupportInfo.supportURL)
        case .feedback:
            guard let url = SupportInfo.feedbackURL(subject: "Feedback") else { return }
            UIApplication.shared.open(url)
        case .siteProblem:
            // The address of the page being complained about, and nothing else
            // about the session.
            let site = webView.url?.absoluteString ?? "no page open"
            guard let url = SupportInfo.feedbackURL(subject: "Site problem: \(site)") else { return }
            UIApplication.shared.open(url)
        }
    }

    /// Open one of the app's own pages in a Safari sheet.
    private func presentSheet(_ address: String) {
        guard let url = URL(string: address) else { return }
        let sheet = SFSafariViewController(url: url)
        sheet.preferredControlTintColor = .tintColor
        present(sheet, animated: true)
    }

    /// Say that a pop-up was refused — and, when the refusal was the browser's
    /// own caution rather than the user's standing instruction, offer it.
    ///
    /// A refusal this blunt has to be visible or it is indistinguishable from a
    /// broken site: a link that does nothing, silently, is the same experience
    /// as a bug.
    ///
    /// Two shapes, from the same builder:
    ///
    /// - **Told.** `onOpen` nil — "Always block pop-ups" is on, the user has
    ///   already given their answer, and there is nothing to ask. Not tappable,
    ///   gone in under two seconds.
    /// - **Asked.** `onOpen` set — the default. Names the destination and
    ///   offers one button, because naming it is what makes the tap a decision
    ///   rather than a reflex. Dwells long enough to be read and reached.
    ///
    /// One at a time. A page calling `window.open` in a loop would otherwise
    /// stack plates up the screen, which is both ugly and the beginnings of a
    /// way to make somebody tap the wrong one.
    private func showPopupNotice(destination host: String?, onOpen: (() -> Void)?) {
        popupNotice?.removeFromSuperview()
        popupNoticeDismissal?.cancel()

        let plate = GlassSurface.makeView(radius: 22, fallback: .systemThickMaterial)
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.isUserInteractionEnabled = onOpen != nil
        plate.alpha = 0

        let label = UILabel()
        label.text = onOpen == nil ? "Pop-up blocked" : (host ?? "Pop-up blocked")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false

        if let onOpen {
            let open = UIButton(type: .system)
            open.setTitle("Open Anyway", for: .normal)
            open.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            open.setContentHuggingPriority(.required, for: .horizontal)
            open.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                dismissPopupNotice()
                onOpen()
            }, for: .touchUpInside)
            row.addArrangedSubview(open)
        }

        plate.contentView.addSubview(row)
        view.addSubview(plate)
        view.bringSubviewToFront(addressCapsule)
        popupNotice = plate

        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            plate.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                          constant: -24),
            plate.heightAnchor.constraint(equalToConstant: 44),
            // Never wider than the screen, however long the host is — the label
            // truncates in the middle instead, which keeps the domain readable
            // when it is the path that is long.
            plate.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            plate.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            row.leadingAnchor.constraint(equalTo: plate.contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: plate.contentView.trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: plate.contentView.centerYAnchor),
        ])

        plate.transform = CGAffineTransform(translationX: 0, y: 10)
        UIView.animate(springDuration: 0.4, bounce: 0.2) {
            plate.alpha = 1
            plate.transform = .identity
        }

        // A plate you can act on has to outlast reading it; one that only
        // reports gets out of the way.
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissPopupNotice() }
        popupNoticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + (onOpen == nil ? 1.6 : 5.5),
                                      execute: dismissal)
    }

    private func dismissPopupNotice() {
        popupNoticeDismissal?.cancel()
        popupNoticeDismissal = nil
        guard let plate = popupNotice else { return }
        popupNotice = nil
        UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseIn]) {
            plate.alpha = 0
        } completion: { _ in
            plate.removeFromSuperview()
        }
    }

    private func presentBookmarks() {
        let list = BookmarksViewController { [weak self] url in
            self?.openTab(url: url)
        }
        present(UINavigationController(rootViewController: list), animated: true)
    }

    /// Print what's on screen. `viewPrintFormatter()` paginates the rendered
    /// page rather than re-fetching it, so what prints is what you were reading
    /// — including anything the blocking rules took out of it.
    private func printCurrentPage() {
        guard hasLoadedPage else { return }
        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = webView.title ?? webView.url?.host ?? "Page"

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printFormatter = webView.viewPrintFormatter()
        controller.present(animated: true) { _, _, error in
            if let error {
                log("[Print] failed: \(error.localizedDescription)")
            }
        }
    }

    private func setupHomeOverlay() {
        homeOverlay.translatesAutoresizingMaskIntoConstraints = false
        homeOverlay.onSubmit = { [weak self] text in self?.handleSubmit(text) }
        homeOverlay.onDismiss = { [weak self] in self?.hideHome() }
        homeOverlay.onSelectTab = { [weak self] id in self?.switchToTab(id) }
        homeOverlay.onCloseTab = { [weak self] id in self?.closeTab(id) }
        // The tabs / history / settings panels are glass cards inside the overlay.
        homeOverlay.panel.onOpenURL = { [weak self] url in self?.openTab(url: url) }
        homeOverlay.panel.onSelectTab = { [weak self] id in self?.switchToTab(id) }
        homeOverlay.panel.onCloseTab = { [weak self] id in self?.closeTab(id) }
        homeOverlay.panel.onCloseAllTabs = { [weak self] in self?.closeAllTabs() }
        // The panel reads history straight from the profile's store.
        homeOverlay.panel.history = profile.history
        homeOverlay.panel.onShowDownloads = { [weak self] in self?.homeOverlay.showDownloads() }
        homeOverlay.panel.onOpenDownload = { [weak self] item in self?.presentDownload(item) }
        homeOverlay.panel.onTogglePrivate = { [weak self] on in
            guard let self else { return }
            guard on else {
                setPrivateBrowsing(false)
                // Reflect what actually happened, rather than letting the
                // button assume the switch went through.
                homeOverlay.panel.isPrivateBrowsing = profile.isPrivate
                return
            }
            enterPrivateBrowsing()
        }
        homeOverlay.panel.onShowContentFiltering = { [weak self] in self?.presentContentFiltering() }
        // Favourites: open one, keep the page you're on, or drop one.
        homeOverlay.favourites.onOpen = { [weak self] url in self?.openTab(url: url) }
        homeOverlay.favourites.onRemove = { [weak self] favourite in
            FavouritesStore.shared.remove(favourite)
            self?.homeOverlay.reloadFavourites()
        }
        homeOverlay.favourites.onAdd = { [weak self] in self?.addFavourite() }

        homeOverlay.panel.onShowLegal = { [weak self] document in
            guard let self else { return }
            let legal = LegalViewController(document: document)
            present(UINavigationController(rootViewController: legal), animated: true)
        }
        homeOverlay.panel.onShowAppIcon = { [weak self] in
            guard let self else { return }
            let icons = AppIconViewController()
            present(UINavigationController(rootViewController: icons), animated: true)
        }
        homeOverlay.panel.onShowHomeBehaviour = { [weak self] in
            guard let self else { return }
            let behaviour = HomeBehaviourViewController()
            present(UINavigationController(rootViewController: behaviour), animated: true)
        }
        homeOverlay.panel.onShowStartBoxButtons = { [weak self] in
            guard let self else { return }
            let buttons = StartBoxButtonsViewController()
            present(UINavigationController(rootViewController: buttons), animated: true)
        }
        homeOverlay.panel.onShowAppearance = { [weak self] in
            guard let self else { return }
            let appearance = AppearanceSettingsViewController()
            present(UINavigationController(rootViewController: appearance), animated: true)
        }
        homeOverlay.panel.onShowMediaSettings = { [weak self] in
            guard let self else { return }
            let media = MediaSettingsViewController()
            present(UINavigationController(rootViewController: media), animated: true)
        }
        homeOverlay.panel.onShowPasswords = { [weak self] in self?.presentPasswordsInfo() }
        homeOverlay.panel.onShowSupport = { [weak self] in
            guard let self else { return }
            let support = SupportOptionsViewController()
            // Every destination opens something over this screen — a Safari
            // sheet or a mail composer — so it is dismissed first and the
            // browser opens it, the same arrangement Safeguards uses for the
            // screens it links to.
            support.onOpen = { [weak self] destination in
                self?.presentedViewController?.dismiss(animated: true) {
                    self?.openSupport(destination)
                }
            }
            present(UINavigationController(rootViewController: support), animated: true)
        }
        homeOverlay.panel.onShowSafeguards = { [weak self] in
            guard let self else { return }
            let safeguards = SafeguardsViewController()
            // Both of these present over the Safeguards screen, which is
            // itself presented — so they are handed back to the browser rather
            // than opened from in there.
            safeguards.onShowContentFiltering = { [weak self] in
                self?.presentedViewController?.dismiss(animated: true) {
                    self?.presentContentFiltering()
                }
            }
            safeguards.onShowPasswords = { [weak self, weak safeguards] in
                guard let self, let safeguards else { return }
                safeguards.present(passwordsInfoAlert(), animated: true)
            }
            present(UINavigationController(rootViewController: safeguards), animated: true)
        }
        homeOverlay.panel.onShowLicences = { [weak self] in
            guard let self else { return }
            let licences = LicencesViewController()
            present(UINavigationController(rootViewController: licences), animated: true)
        }
        swipeBindingObserver = NotificationCenter.default.addObserver(
            forName: .swipeBindingChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.configureSwipeDownBehaviour()
        }
        homeOverlay.onStartNewTab = { [weak self] in self?.nextSubmitOpensNewTab = true }
        homeOverlay.onDismissed = { [weak self] in
            // Whatever closed the box, the next opening decides afresh where the
            // address goes — a stale flag would put it in the wrong tab.
            self?.nextSubmitOpensNewTab = false
            guard let self, reloadWhenOverlayCloses else { return }
            reloadWhenOverlayCloses = false
            guard hasLoadedPage, webView.url != nil else { return }
            webView.reload()
        }
        homeOverlay.panel.onOpenSupport = { [weak self] destination in
            self?.openSupport(destination)
        }
        homeOverlay.panel.onConfirmDestructive = { [weak self] title, consequence, act in
            guard let self else { return }
            // An alert on iOS 26, an action sheet before it.
            //
            // Through iOS 18 the sheet is the right shape for this: it rises
            // from the bottom, full width, with room for a sentence explaining
            // what is about to be destroyed. iOS 26 renders the same sheet as a
            // small popover tethered to its source view, and the explanation —
            // which is the entire reason for the prompt — gets clipped after a
            // line and a half. A warning nobody can finish reading is not a
            // warning.
            //
            // An alert is centred, sized to its text, and unchanged in shape
            // across both. Only the newer platform is moved, because on the
            // older one the sheet is better and there is no reason to lose it.
            let centred: Bool
            if #available(iOS 26.0, *) { centred = true } else { centred = false }

            let alert = UIAlertController(title: title, message: consequence,
                                          preferredStyle: centred ? .alert : .actionSheet)
            alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in act() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            // An action sheet on iPad is a popover, and it insists on knowing
            // what it is popping out of. Harmless on the alert path, which has
            // no popover controller to configure.
            alert.popoverPresentationController?.sourceView = homeOverlay.panel
            alert.popoverPresentationController?.sourceRect = homeOverlay.panel.bounds
            present(alert, animated: true)
        }
        homeOverlay.panel.onClearHistory = { [weak self] in self?.forgetNavigationHistory() }
        homeOverlay.panel.onShredAppData = { [weak self] in self?.shredAppData() }
        homeOverlay.panel.onClearWebsiteData = { [weak self] in
            // Clear the *profile's* store — clearing `.default()` from a private
            // profile would wipe the wrong session's data.
            guard let store = self?.profile.websiteDataStore else { return }
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                             modifiedSince: .distantPast) { }
        }
        view.addSubview(homeOverlay)
        NSLayoutConstraint.activate([
            homeOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            homeOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            homeOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            homeOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Erase the session: both profiles, every tab, the downloads list, and
    /// anything left in the address field.
    ///
    /// Clear History & Website Data forgets where you have been while leaving
    /// you where you are. This is the other request — hand the phone over with
    /// nothing on it — so it takes the tabs too, and takes them from the
    /// private profile as well. A shred that left a private tab open would be
    /// worse than not offering one at all, since the whole point is being able
    /// to say the app is empty and be right.
    ///
    /// Kept: only the files already saved into Files. Those are documents the
    /// user has, not traces of a session, and deleting somebody's documents is
    /// not something a button in a browser should do quietly.
    ///
    /// Everything else goes, settings included — which means the welcome screen
    /// comes back on next launch, since `hasSeenWelcome` was a setting like any
    /// other. Right rather than unfortunate: what is left is a fresh install.
    private func shredAppData() {
        // The live web view holds a page, a back/forward list and a process of
        // its own, none of which any store can reach. It goes first, so nothing
        // below is racing a page that is still loading.
        stashSessionState()
        teardownWebView()

        normalProfile.clearAllBrowsingData()
        privateProfile?.clearAllBrowsingData()
        // Dropped entirely rather than emptied: it is in-memory storage, so a
        // fresh one is genuinely fresh, and leaving private browsing after this
        // would otherwise return to the same instance.
        privateProfile = nil
        if profile !== normalProfile { profile = normalProfile }

        DownloadManager.shared.clearAll()
        BookmarkStore.shared.removeAll()
        FavouritesStore.shared.removeAll()
        // The wallpaper is a file the user chose and a key saying which; both go.
        WallpaperStore.clear()
        // Last of the stores, because the settings above are read while the
        // others are being torn down.
        Settings.resetToDefaults()
        popupAllowedHosts.removeAll()
        currentScriptlet = nil
        contentProcessCrashes = 0

        installWebView()
        restoreChromeAfterWebViewSwap()
        tabManager.delegate = self

        hasLoadedPage = false
        addressCapsule.isHidden = true
        webView.load(URLRequest(url: URL(string: "about:blank")!))

        homeOverlay.panel.history = profile.history
        homeOverlay.panel.isPrivateBrowsing = false
        homeOverlay.clearAddressField()
        homeOverlay.setTabs(tabs, current: currentTabID)

        // Settings are back at their defaults, and every one of these is a
        // setting somebody can see. Re-read them now rather than leaving the
        // app wearing choices that no longer exist anywhere.
        applyAppearance()
        applyContentBlocking()
        applyZoomPolicy()
        homeOverlay.reloadWallpaper()
        homeOverlay.reloadFavourites()
        homeOverlay.reloadStartBoxButtons()
    }

    // MARK: - Private browsing

    /// Swap the whole profile: database, tab session and website data store.
    ///
    /// Private browsing here is not a flag the browser checks in fifty places —
    /// it's a second profile with in-memory storage, and this points the browser
    /// at it. The web view has to be rebuilt because its data store is fixed at
    /// creation; that also guarantees no page, cache entry or cookie survives the
    /// switch, which is the property that makes it private at all.
    ///
    /// The tab box stays open across the switch, showing the other set of tabs.
    /// Enter private browsing, asking for Face ID first if that is switched on.
    ///
    /// The way in only. Leaving private browsing reveals nothing that was
    /// hidden, so a prompt on the way out would be a lock on your own phone and
    /// nothing else.
    ///
    /// Refusal is silent and leaves the button where it was — the prompt itself
    /// already said what was being asked, and a second message saying it didn't
    /// happen tells nobody anything. On a device with no passcode set there is
    /// no secret to check against, and `BiometricGate` lets the caller through
    /// rather than sealing the mode off; the setting is hidden there too.
    private func enterPrivateBrowsing(then completion: (() -> Void)? = nil) {
        guard !profile.isPrivate else { completion?(); return }
        guard Settings.requirePrivateAuth else {
            setPrivateBrowsing(true)
            homeOverlay.panel.isPrivateBrowsing = profile.isPrivate
            completion?()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let granted = await BiometricGate.authenticate(
                reason: "Unlock private browsing.")
            guard granted else {
                homeOverlay.panel.isPrivateBrowsing = profile.isPrivate
                return
            }
            setPrivateBrowsing(true)
            homeOverlay.panel.isPrivateBrowsing = profile.isPrivate
            completion?()
        }
    }

    private func setPrivateBrowsing(_ on: Bool) {
        guard on != profile.isPrivate else { return }

        // Bank the outgoing profile's session before anything is torn down.
        stashSessionState()
        profile.shutdown()

        if on {
            if privateProfile == nil {
                privateProfile = BrowserProfile(localName: "profile.private", isPrivate: true)
            }
            profile = privateProfile!
        } else {
            profile = normalProfile
        }

        currentScriptlet = nil          // belonged to the page that just went away
        popupAllowedHosts.removeAll()   // granted to the profile that just went away
        contentProcessCrashes = 0
        rebuildWebView()

        // The panels read straight from the profile, so they have to be re-pointed
        // as well or private browsing would list the normal profile's history.
        homeOverlay.panel.history = profile.history
        homeOverlay.panel.isPrivateBrowsing = on
        tabManager.delegate = self
        homeOverlay.setTabs(tabs, current: currentTabID)

        // Show whatever that profile was last on. A first entry into private
        // browsing has no tabs, so the page behind the box is simply blank.
        if let tab = tabManager.selectedTab {
            hasLoadedPage = true
            load(tab)
        } else {
            hasLoadedPage = false
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        // The box is still up, so the refresh button stays out of the way until
        // it is dismissed.
        addressCapsule.isHidden = true
    }

    /// Replace the web view with one built for the current profile, keeping the
    /// chrome that sits around it.
    /// Throw away every back/forward list, not just the history database.
    ///
    /// Clearing history used to empty the list in the panel and nothing else,
    /// while the addresses stayed in two other places: each tab's stored
    /// `interactionState`, which is the whole back/forward list written to disk,
    /// and the live web view's own list in memory. So after clearing you could
    /// still swipe back through the pages you had just forgotten, and they
    /// survived a relaunch. "Every page you have visited, forgotten" is what the
    /// confirmation promises, and it has to be true.
    ///
    /// The live list cannot be emptied — WebKit exposes no way to — so the web
    /// view is replaced, which is the only thing that drops it. The page you are
    /// on stays; only the trail behind it goes.
    private func forgetNavigationHistory() {
        for tab in tabs {
            tabManager.setSessionState(nil, for: tab.id)
        }

        guard hasLoadedPage, let current = webView.url, current.isWebPage else { return }
        rebuildWebView()
        webView.load(pageRequest(current))
    }

    /// Take a pop-up's web view and make it the current tab.
    ///
    /// `createWebViewWith` must return a live web view built from WebKit's own
    /// configuration, which is why a pop-up could not simply become a tab and
    /// why it used to be shown as a sheet instead. But nothing says the web
    /// view it returns cannot be *this* browser's web view from that moment on:
    /// the outgoing page is banked as its tab's session state, the new view
    /// takes its place, and WebKit loads the pop-up into it as normal.
    ///
    /// What is given up is the opener. The page that called `window.open` is no
    /// longer running in a live web view, so nothing can be posted back to it —
    /// which is exactly why sign-ins still get the sheet, and only they.
    private func adoptPopupAsTab(_ adopted: WKWebView, url: URL) {
        stashSessionState()
        teardownWebView()
        installWebView(adopting: adopted)
        restoreChromeAfterWebViewSwap()

        hasLoadedPage = true
        homeOverlay.dismiss(animated: true)
        // WebKit loads the request itself once this returns, so the tab is
        // registered without one — `load(tab)` here would fetch the page a
        // second time and throw away the window WebKit just created.
        adoptingPopup = true
        tabManager.addTab(url: url)
        adoptingPopup = false
    }

    private func teardownWebView() {
        // Drop every observation first: they hold the old web view, and a KVO
        // callback arriving mid-swap would apply the old page's state to the new
        // one.
        progressObservation = nil
        themeColorObs = nil
        underPageObs = nil
        scrollObs = nil
        zoomObs = nil
        urlObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()
    }

    private func rebuildWebView() {
        teardownWebView()
        installWebView()
        restoreChromeAfterWebViewSwap()
    }

    private func restoreChromeAfterWebViewSwap() {
        // The web view is added on top of everything; put the chrome back in
        // front of it.
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(addressCapsule)
        view.bringSubviewToFront(homeOverlay)
        // The reveal gesture was attached to the web view that just went away.
        setupGestures()
        applyContentBlocking()
        applyTopColor()
        resetProgress()
    }

    /// Which rule lists are in use — bundled ones, lists the user subscribed to
    /// by URL, and their own rules. The blocking level in Privacy decides how
    /// hard those rules are applied; this decides which rules exist.
    private func presentContentFiltering() {
        let filtering = ContentFilteringViewController()
        present(UINavigationController(rootViewController: filtering), animated: true)
    }

    /// Passwords are the system's, not ours.
    ///
    /// A browser storing credentials itself means owning an encrypted store, its
    /// migrations and its backups — and being the thing that leaks them. iOS
    /// already fills passwords into a `WKWebView` from the keychain or whichever
    /// password manager the user chose, with the approval prompt shown by that
    /// app rather than by us. So this explains where they live instead of
    /// offering a second, worse place to keep them.
    /// Built rather than presented, because Safeguards has to show this over
    /// itself — it is presented, so the browser cannot present over it.
    private func passwordsInfoAlert() -> UIAlertController {
        let alert = UIAlertController(
            title: "Passwords",
            message: "Saved passwords come from iOS — iCloud Keychain, or whichever "
                   + "password manager you use. They fill into sign-in forms straight "
                   + "from the keyboard, and this browser never sees or stores them.\n\n"
                   + "Manage them in Settings › General › AutoFill & Passwords.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        return alert
    }

    private func presentPasswordsInfo() {
        present(passwordsInfoAlert(), animated: true)
    }

    /// Backstop for same-document navigation: any URL change we didn't already
    /// record. The JS bridge below catches these first and more precisely; this
    /// covers pages where the injected script never ran.
    private func observeSameDocumentNavigations() {
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            guard let self, let url = webView.url else { return }
            // The URL change produced by a document navigation belongs to that
            // navigation, which records itself at commit.
            guard url != self.pendingNavigationURL else { return }
            self.recordSameDocumentVisit(url: url, transition: .sameDocument)
        }
    }

    /// Record a same-document navigation, from either the JS bridge or the KVO
    /// backstop. Both can see the same event, so an identical URL inside a short
    /// window is treated as one navigation — while the *same* URL visited again
    /// later still counts, because revisiting a page is a real visit.
    private func recordSameDocumentVisit(url: URL, transition: VisitTransition) {
        // Internal schemes aren't places the user went. The store filters these
        // too; doing it here as well keeps junk out of the tab list, which the
        // store never sees.
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }
        if url == lastRecordedURL, Date().timeIntervalSince(lastRecordedAt) < 0.3 { return }
        recordVisit(url: url, transition: transition)
        // Keep the tab list honest — the address changed under it.
        tabManager.updateSelectedTab(url: url)
        adoptTitleWhenItArrives(for: url)
    }

    /// Pick up the title a single-page app sets *after* it changes route.
    ///
    /// On a normal load the title is patched in at `didFinish`. A route change
    /// inside one document never finishes a navigation, so nothing was ever
    /// coming back for it — the visit kept whatever `document.title` said at the
    /// moment the URL changed, which on a video site is the title of the video
    /// you were watching *before*. Hence a history full of the same name.
    ///
    /// The app rewrites the title within a few hundred milliseconds of the
    /// route change, so this looks once, shortly after, and only if the page is
    /// still where it was.
    private func adoptTitleWhenItArrives(for url: URL) {
        titleWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.webView.url == url else { return }
            let title = self.webView.title ?? ""
            guard !title.isEmpty else { return }
            self.profile.history.updateTitle(url: url, title: title)
            self.tabManager.updateSelectedTab(url: url, title: title)
        }
        titleWatchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Log a visit. The store chains it to the previous one on its own queue, so
    /// nothing here waits on the database.
    private func recordVisit(url: URL, transition: VisitTransition) {
        profile.history.recordVisit(url: url,
                                    title: webView.title ?? "",
                                    transition: transition)
        lastRecordedURL = url
        lastRecordedAt = Date()
    }

    /// Preview a finished download — Quick Look for what it can render, and the
    /// share sheet ("Save to Files", "Open in…") for everything else.
    private func presentDownload(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.fileURL.path) else {
            let alert = UIAlertController(title: "File missing",
                                          message: "This download is no longer on disk.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let controller = UIDocumentInteractionController(url: item.fileURL)
        controller.delegate = self
        documentPreview = controller           // the controller doesn't retain itself
        if !controller.presentPreview(animated: true) {
            controller.presentOptionsMenu(from: view.bounds, in: view, animated: true)
        }
    }

    private func setupGestures() {
        // A pan, not a swipe. `UISwipeGestureRecognizer` recognises at a fixed
        // distance it doesn't expose, so how far you have to drag could never be
        // a setting. A pan reports the distance and lets the threshold be one.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(revealPanChanged))
        pan.delegate = self
        // The page keeps its touches. At the top of a document a downward drag
        // only rubber-bands, and taking that away would make the page feel stuck
        // while the drag is still being measured.
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        webView.addGestureRecognizer(pan)
        revealPan = pan

        configureSwipeDownBehaviour()
    }

    /// Open the start page once the drag has gone far enough down.
    ///
    /// Fires mid-gesture rather than on release, which is what the swipe
    /// recogniser did and what the drag should still feel like.
    @objc private func revealPanChanged(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .changed:
            guard !revealPanFired else { return }
            let moved = pan.translation(in: view)
            // Downward, and more vertical than horizontal — a diagonal drag
            // belongs to the page.
            guard moved.y >= Settings.revealSwipeDistance,
                  abs(moved.y) > abs(moved.x) * 1.5 else { return }
            revealPanFired = true
            revealHome()
        case .ended, .cancelled, .failed:
            revealPanFired = false
        default:
            break
        }
    }

    /// Point the downward drag at whichever job the user picked.
    ///
    /// The two are different gestures, not one gesture with a branch, and that
    /// is the whole point. Revealing the start box is a flick: it either
    /// happened or it didn't, which is exactly what a swipe recogniser reports.
    /// Reloading is a *drag* — you pull, an indicator follows your finger, and
    /// past a threshold letting go commits it; scroll back before then and
    /// nothing happens. Driving that from a swipe recogniser produced a page
    /// that reloaded off a flick, with no indicator, no threshold and no way to
    /// change your mind. `UIRefreshControl` on the web view's own scroll view
    /// is the real thing, and it is what every other browser puts there.
    private func configureSwipeDownBehaviour() {
        let wantsReload = !Settings.swipeOpensStartBox
        revealPan?.isEnabled = !wantsReload

        guard wantsReload else {
            pullToRefresh?.endRefreshing()
            webView.scrollView.refreshControl = nil
            pullToRefresh = nil
            return
        }
        // Rebuilt rather than reused: a web view swap leaves the old control
        // attached to a scroll view that no longer exists.
        let control = UIRefreshControl()
        control.addTarget(self, action: #selector(pullToRefreshFired), for: .valueChanged)
        webView.scrollView.refreshControl = control
        pullToRefresh = control
    }

    @objc private func pullToRefreshFired() {
        // Committed at this point, so it gets the same acknowledgement a
        // deliberate reload gets: a tick you can feel, on top of the control's
        // own spinner.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        webView.reload()
    }

    /// Stop the spinner once the load it started has finished, one way or the
    /// other. Left running, it sits there spinning over a page that finished
    /// loading a while ago.
    private func endPullToRefresh() {
        guard let pullToRefresh, pullToRefresh.isRefreshing else { return }
        pullToRefresh.endRefreshing()
    }

    // MARK: - Home overlay

    private func showHome(animated: Bool) {
        addressCapsule.isHidden = true
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: animated)
    }

    @objc private func revealHome() { revealHome(editingCurrentURL: false) }

    /// - Parameter editingCurrentURL: whether this is an edit of the address
    ///   you are on, rather than the start of something new.
    ///
    ///   The distinction belongs to the box, not to the gesture that opened it:
    ///   an edit carries the current URL and commits **in the same tab**, while
    ///   everything else commits into a new one. Without it, opening the box
    ///   from the capsule would silently turn every address correction into a
    ///   new tab — which is what the box does today for every commit.
    private func revealHome(editingCurrentURL: Bool) {
        addressCapsule.isHidden = true
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        // Snapshot the page we're leaving so its grid card shows a live preview.
        captureSnapshot { [weak self] in
            guard let self else { return }
            self.homeOverlay.setTabs(self.tabs, current: self.currentTabID)
        }
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: true,
                            editing: editingCurrentURL ? webView.url : nil)
    }

    /// Move to the tab either side of this one. Inert with one tab open.
    private func switchTab(by step: Int) {
        guard tabs.count > 1,
              let current = currentTabID,
              let index = tabs.firstIndex(where: { $0.id == current }) else { return }
        // Wraps: with a handful of tabs, running off the end and stopping dead
        // is more surprising than coming round.
        let next = (index + step + tabs.count) % tabs.count
        UISelectionFeedbackGenerator().selectionChanged()
        switchToTab(tabs[next].id)
    }

    /// Capture a downscaled snapshot of the visible page into the current tab.
    private func captureSnapshot(completion: (() -> Void)? = nil) {
        guard hasLoadedPage, let id = currentTabID else { completion?(); return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 320   // points; plenty for a grid card
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            self?.tabManager.setSnapshot(image, for: id)
            completion?()
        }
    }

    /// Fetch the site's own favicon (privacy-preserving — assets from the site we
    /// already visited, no third-party icon service). Prefers the PNG
    /// apple-touch-icon / <link icon> and falls back to /favicon.ico.
    private func fetchFavicon(for id: UUID) {
        let js = """
        (function(){
          var rels=["apple-touch-icon","apple-touch-icon-precomposed","icon","shortcut icon"];
          for(var i=0;i<rels.length;i++){
            var l=document.querySelector("link[rel='"+rels[i]+"']")||document.querySelector("link[rel~='"+rels[i]+"']");
            if(l&&l.href) return l.href;
          }
          // `location.origin` is the *string* "null" on an opaque origin — our
          // own error page, about:blank, a data: URL — and concatenating it
          // asks the network for "null/favicon.ico".
          if(location.protocol!=="http:"&&location.protocol!=="https:") return "";
          return location.origin+"/favicon.ico";
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let str = result as? String, !str.isEmpty,
                  let iconURL = URL(string: str), iconURL.scheme?.hasPrefix("http") == true
            else { return }
            Self.faviconSession.dataTask(with: iconURL) { [weak self] data, _, _ in
                guard let self, let data, let image = UIImage(data: data) else { return }  // .ico may not decode
                DispatchQueue.main.async {
                    self.tabManager.setIcon(image, for: id)
                }
            }.resume()
        }
    }

    /// Favicons are fetched outside the web view, so they need a session of their
    /// own. `URLSession.shared` would carry the app's shared cookie storage and
    /// write the response into the on-disk cache — for a private profile, whose
    /// whole point is leaving nothing behind, that would be a hole straight
    /// through it. Ephemeral keeps both in memory, and cookies are refused
    /// outright: an icon request has no business carrying or setting any.
    ///
    /// Ten seconds, against a default of sixty. A favicon is decoration: if it
    /// has not arrived by now the tab shows its globe and nothing is worse for
    /// it. Sixty seconds of waiting for one buys a connection held open against
    /// a host that is not answering, on a page whose real requests are queued
    /// behind the same few sockets — so the cost of the default lands on the
    /// page, not on the icon.
    private static let faviconSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 10
        // The whole errand, retries included — a host that answers a byte at a
        // time would otherwise keep resetting the per-request timer above.
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config)
    }()

    private func hideHome() {
        guard hasLoadedPage else { return }   // nothing behind to reveal yet
        homeOverlay.dismiss(animated: true)
        // Nothing is navigating, so nothing will commit — the capsule has to be
        // put back explicitly or it stays hidden over a live page.
        addressCapsule.show(url: webView.url)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        applyZoomPolicy()
    }

    // MARK: - Navigation

    private func handleSubmit(_ raw: String) {
        guard let url = URLResolver.resolve(raw) else { return }
        // Typed URLs and searches are the strongest signal of intent, and rank
        // highest — but WebKit reports them as `.other`, so flag it here.
        nextNavigationIsTyped = true

        // A new tab only when something asked for one, or when there is no tab
        // to load into — the second case is a first launch, where every address
        // has to make the tab it opens in.
        let wantsNewTab = nextSubmitOpensNewTab
        nextSubmitOpensNewTab = false

        guard !wantsNewTab, hasLoadedPage, tabManager.selectedTab != nil else {
            openTab(url: url)
            return
        }

        hasLoadedPage = true
        homeOverlay.dismiss(animated: true)
        // Shown by `didCommit`, once there is an origin to show.
        tabManager.updateSelectedTab(url: url)
        webView.load(pageRequest(url))
    }

    /// Open a URL in a new tab and make it current.
    /// - Parameter startsNewChain: whether this page is unrelated to the one on
    ///   screen. True for a typed address. False for a popup, which descends
    ///   from the page that opened it and belongs in the same visit chain.
    private func openTab(url: URL, startsNewChain: Bool = true) {
        // Bank the outgoing tab's back/forward list before the web view moves on.
        stashSessionState()
        // A typed address starts a new visit chain — this page didn't descend
        // from whatever was on screen.
        if startsNewChain { profile.history.resetVisitChain() }
        hasLoadedPage = true
        homeOverlay.dismiss(animated: true)
        // Shown by `didCommit`, once there is an origin to show.
        tabManager.addTab(url: url)      // selection callback loads it
    }

    private func switchToTab(_ id: UUID) {
        guard id != currentTabID else {
            homeOverlay.dismiss(animated: true)
            // Same tab: the box just closes, and no load follows to reveal it.
            addressCapsule.show(url: webView.url)
            return
        }
        stashSessionState()
        hasLoadedPage = true
        homeOverlay.dismiss(animated: true)
        // Shown by `didCommit`, once there is an origin to show.
        tabManager.selectTab(id: id)     // selection callback loads it
    }

    private func closeTab(_ id: UUID) {
        tabManager.removeTab(id: id)     // selection callback loads the neighbour
    }

    /// Drive the capsule's hairline from the web view's real load progress.
    ///
    /// `estimatedProgress` arrives in lurches rather than smoothly, which a line
    /// absorbs far better than a fill would — and a fill over glass would mute
    /// the refraction the material is made of, under the domain text, at the
    /// moment the user is trying to read it.
    ///
    /// A cached load finishes almost instantly, and a capsule this narrow gives
    /// the line so little travel that the result reads as a glitch rather than
    /// as progress. So nothing is drawn until a load has been running long
    /// enough to be worth reporting — Safari suppresses fast loads for the same
    /// reason.
    private func updateProgress(_ value: Float) {
        guard progressDeserved else { return }
        if value < 1.0 {
            addressCapsule.setProgress(Double(max(0.04, value)), animated: true)
        } else {
            addressCapsule.finishProgress()
        }
    }

    /// Cancel any in-flight progress display (failed or cancelled navigation).
    private func resetProgress() {
        progressTimer?.invalidate()
        progressTimer = nil
        progressDeserved = false
        addressCapsule.resetProgress()
    }

    /// Start the clock that decides whether this load gets an indicator at all.
    private func beginProgress() {
        progressTimer?.invalidate()
        progressDeserved = false
        addressCapsule.resetProgress()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) {
            [weak self] _ in
            guard let self, webView.isLoading else { return }
            progressDeserved = true
            addressCapsule.setProgress(Double(max(0.04, webView.estimatedProgress)),
                                       animated: false)
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        beginProgress()
        sawServerRedirect = false
        pendingNavigationURL = webView.url
    }

    /// A 3xx moved us mid-flight. The visit that eventually commits was reached by
    /// redirect, which ranks far lower than a page the user chose.
    func webView(_ webView: WKWebView,
                 didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        sawServerRedirect = true
    }

    /// The navigation committed — the page is now the one on screen. This is
    /// where a visit belongs: `didFinish` never fires for a load the user
    /// interrupts, and browsers record those visits too.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // The address is settled at commit — this is the first moment it is
        // safe to say which site you are on, and the last moment it changes.
        addressCapsule.show(url: webView.url)
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        applyZoomPolicy()
        guard let url = webView.url else { return }
        // A redirect outranks the original classification: it's how we got here.
        let transition: VisitTransition = sawServerRedirect ? .redirect : pendingTransition
        recordVisit(url: url, transition: transition)
        // A new document replaces whatever was playing, so the audio session
        // goes back to the system until the next page starts media of its own.
        remoteMedia.endPlayback()
        // Scriptlets evaluated for route changes belonged to the document that
        // just went away; this one has its own injected at document start.
        sameDocumentScriptlet = nil
        pendingTransition = .link       // back to the default for the next one
        sawServerRedirect = false
        // The document is on screen; any further URL change is same-document.
        pendingNavigationURL = nil
    }

    /// A load that dies after content started arriving.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    /// A load that dies before any content arrives (DNS, TLS, offline, timeout).
    /// Without this the ring used to sit frozen mid-way and the page stayed blank.
    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        endPullToRefresh()
        resetProgress()
        pendingNavigationURL = nil  // nothing is in flight anymore
        let ns = error as NSError
        // -999 is "cancelled" — a normal consequence of starting a new load.
        guard ns.code != NSURLErrorCancelled else { return }
        // "Frame load interrupted" is what WebKit reports for a navigation we
        // deliberately turned into a download or blocked by policy. The page
        // didn't fail; there's nothing to tell the user.
        guard !(ns.domain == "WebKitErrorDomain" && ns.code == 102) else { return }
        log("[Nav] load failed: \(ns.code) \(ns.localizedDescription)")
        // A provisional failure leaves `webView.url` nil — nothing ever committed
        // — so take the address out of the error, which is the only place it
        // survives. Without it the error page has nothing to retry.
        let failedURL = ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        showErrorPage(message: ns.localizedDescription, url: failedURL)
    }

    /// The web content process was killed (memory pressure on heavy pages).
    /// Without this the view stays permanently blank — the classic "site died
    /// halfway and never came back".
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resetProgress()

        // Backgrounded apps get their content process jettisoned routinely. That
        // isn't a failure — reloading now would be wasted work (and often fails),
        // so wait until we're visible again.
        guard UIApplication.shared.applicationState == .active else {
            needsReloadOnForeground = true
            log("[Nav] content process jettisoned while backgrounded — deferring reload")
            return
        }

        contentProcessCrashes += 1
        guard contentProcessCrashes <= maxCrashRecoveryAttempts else {
            // Reloading again would just crash again; stop and tell the user.
            log("[Nav] content process crashed \(contentProcessCrashes)× — giving up")
            showErrorPage(message: "This page used too much memory and stopped responding.")
            contentProcessCrashes = 0
            return
        }

        log("[Nav] content process terminated (attempt \(contentProcessCrashes)) — reloading")
        reloadCurrentPage()
    }

    /// Reload whatever the current tab should be showing. After a process crash
    /// `webView.url` can be nil, so fall back to the tab's stored URL.
    private func reloadCurrentPage() {
        if let url = webView.url ?? tabs.first(where: { $0.id == currentTabID })?.url {
            webView.load(pageRequest(url))
        } else {
            webView.reload()
        }
    }

    /// Catch the blank page an expired link leaves behind.
    ///
    /// A 404 or 410 with no body is a *successful* navigation as far as WebKit is
    /// concerned, so none of the failure delegates run — the load simply finishes
    /// having rendered nothing. The status alone isn't enough to act on, because
    /// a good custom 404 page is also a 4xx and replacing it would be worse. So
    /// the document is asked whether it actually rendered anything, and only a
    /// genuinely empty one is replaced.
    private func checkForEmptyErrorPage() {
        guard let status = lastMainFrameStatus, status >= 400 else { return }
        // Consume it now: `loadHTMLString` below finishes as its own navigation,
        // and leaving the status set would make that re-enter here forever.
        lastMainFrameStatus = nil

        let failedURL = webView.url
        webView.evaluateJavaScript(
            Self.paintedContentProbe
        ) { [weak self] result, _ in
            guard let self,
                  let visible = result as? Int, visible == 0,
                  // The page may have moved on while we were asking.
                  self.webView.url == failedURL else { return }
            let reason = HTTPURLResponse.localizedString(forStatusCode: status)
                .capitalizingFirstLetter()
            log("[Nav] \(status) with an empty body — showing an error page")
            self.showErrorPage(message: "\(reason) (\(status))", url: failedURL)
        }
    }

    /// Asks the page whether it rendered anything at all.
    ///
    /// Text and images alone were too narrow: a player, a map or a chart draws
    /// into a canvas, video or SVG and has neither, and calling those blank
    /// would reload a page that was working.
    private static let paintedContentProbe =
        "(document.body ? document.body.innerText.trim().length : 0)" +
        " + (document.images ? document.images.length : 0)" +
        " + document.querySelectorAll('canvas,video,svg,iframe,input,button').length"

    /// Bring back a page that finished loading and painted nothing.
    ///
    /// Going back — usually by the edge-swipe gesture — can land on a
    /// back/forward entry WebKit can no longer reproduce: the page was dropped
    /// from its cache and what it holds isn't enough to rebuild. The navigation
    /// does not fail. It commits, `didFinish` runs, no delegate reports an
    /// error, and the result is a correctly loaded empty document. Nothing in
    /// the failure paths can see it, which is why it survived them all.
    ///
    /// Same answer Brave gives a tab whose web view has nothing to show —
    /// `reloadFromOrigin`, and from origin because whatever is cached is
    /// precisely what came back empty.
    ///
    /// Guarded per URL: a page that paints nothing twice is genuinely empty, and
    /// reloading it again would be a loop.
    private func recoverIfPagePaintedNothing() {
        guard let url = webView.url, url.isWebPage, url != blankRecoveryURL else { return }

        // Long enough for a first paint. Probing at `didFinish` reports empty on
        // pages that are merely still laying out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !webView.isLoading, webView.url == url else { return }
            webView.evaluateJavaScript(Self.paintedContentProbe) { [weak self] result, _ in
                guard let self, let painted = result as? Int else { return }
                guard painted == 0 else {
                    // It came back fine, so the next blank on this URL is new.
                    if self.blankRecoveryURL == url { self.blankRecoveryURL = nil }
                    return
                }
                guard !self.webView.isLoading, self.webView.url == url else { return }
                log("[Nav] page finished but painted nothing — reloading \(url)")
                self.blankRecoveryURL = url
                self.webView.reloadFromOrigin()
            }
        }
    }

    private func showErrorPage(message: String, url: URL? = nil) {
        let escaped = message.replacingOccurrences(of: "<", with: "&lt;")
        let html = """
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>
          body { font: -apple-system-body; font-family: -apple-system, system-ui;
                 display:flex; align-items:center; justify-content:center;
                 height:100vh; margin:0; text-align:center;
                 background:#f2f2f7; color:#1c1c1e; }
          @media (prefers-color-scheme: dark) { body { background:#1c1c1e; color:#f2f2f7; } }
          .box { padding:0 32px; max-width:420px; }
          h1 { font-size:19px; margin:0 0 8px; }
          p  { font-size:15px; opacity:.6; margin:0; }
        </style></head>
        <body><div class="box"><h1>Can’t open this page</h1><p>\(escaped)</p></div></body></html>
        """
        // Load against the failed URL where we know it. With a nil base the web
        // view's URL becomes about:blank, which loses the address and leaves the
        // refresh button reloading nothing — so an expired page could never be
        // retried once it had failed. The markup is our own and carries no
        // script, so borrowing the origin costs nothing.
        webView.loadHTMLString(html, baseURL: url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        addressCapsule.show(url: webView.url)
        endPullToRefresh()
        contentProcessCrashes = 0   // a clean load means we've recovered
        pendingNavigationURL = nil  // backstop: a commit we somehow missed
        checkForEmptyErrorPage()
        recoverIfPagePaintedNothing()
        // Keep the current tab's title/URL fresh for the list.
        guard let tab = tabManager.selectedTab else { return }
        let pageTitle = webView.title ?? ""
        let resolvedTitle = pageTitle.isEmpty ? (webView.url?.host ?? tab.title) : pageTitle
        // about:blank finishing loading is not a page the tab should remember —
        // that's a failed restore or a teardown, and recording it would replace
        // the tab's address and session with a blank one for good.
        let isRealPage = webView.url?.isWebPage == true
        tabManager.updateSelectedTab(url: webView.url,
                                     title: resolvedTitle,
                                     sessionState: isRealPage
                                         ? webView.interactionState as? Data : nil)
        // The visit was recorded at commit; the title only resolves now, so patch
        // it in rather than logging a second visit.
        if let url = webView.url {
            profile.history.updateTitle(url: url, title: resolvedTitle)
        }
        // Pull the site's favicon for the tab row.
        fetchFavicon(for: tab.id)
        // Give the tab a preview once the page has painted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.captureSnapshot()
        }
    }

    /// Map WebKit's navigation type onto the transition kinds history records.
    /// A URL the user typed arrives as `.other` — indistinguishable from a
    /// script-driven load — so the caller flags it separately.
    private static func transition(for type: WKNavigationType,
                                   typed: Bool) -> VisitTransition {
        switch type {
        case .linkActivated:   return .link
        case .formSubmitted,
             .formResubmitted: return .formSubmit
        case .backForward:     return .backForward
        case .reload:          return .reload
        case .other:           return typed ? .typed : .link
        @unknown default:      return .link
        }
    }

    // Refuse non-web schemes (itms-apps, market, tel, custom app schemes) so a
    // page can't bounce the browser into the App Store or another app.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        // Classify the navigation now; the commit handler logs it. Only main-frame
        // navigations describe where the *user* went — subframe loads are the
        // page's business, and browsers keep them out of the visible history.
        if navigationAction.targetFrame?.isMainFrame ?? false {
            pendingTransition = Self.transition(for: navigationAction.navigationType,
                                                typed: nextNavigationIsTyped)
            nextNavigationIsTyped = false
        }
        // HTTPS-only: retry insecure loads over https instead.
        if Settings.httpsOnly, url.scheme?.lowercased() == "http",
           var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.scheme = "https"
            if let secure = comps.url {
                decisionHandler(.cancel)
                pendingTransition = .redirect     // we moved them, they didn't ask
                webView.load(pageRequest(secure))
                return
            }
        }
        let allowed: Set<String> = ["http", "https", "about", "data", "blob"]
        let scheme = url.scheme?.lowercased() ?? ""
        if !allowed.contains(scheme) {
            decisionHandler(.cancel)
            resetProgress()          // otherwise the ring freezes on the dead load
            // Hand off the everyday communication schemes, but only when the user
            // actually tapped a link — never for an automatic redirect, which is
            // how ad pages bounce you into the App Store.
            let handoff: Set<String> = ["mailto", "tel", "sms", "facetime", "maps"]
            if handoff.contains(scheme), navigationAction.navigationType == .linkActivated {
                UIApplication.shared.open(url)
            } else {
                log("[Nav] blocked external scheme: \(scheme)")
            }
            return
        }
        // Last step before allowing: put any scriptlet for this URL in place.
        // It has to be a user script injected at document start, and user scripts
        // are fixed once a navigation begins — so the set is rebuilt here, while
        // this navigation is still pending. A server redirect calls back into
        // this method, so the scriptlet is re-evaluated for the real destination.
        guard navigationAction.targetFrame?.isMainFrame ?? false,
              Settings.blockingLevel != .off,
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        Task { @MainActor [weak self] in
            await self?.installScriptlet(for: url)
            decisionHandler(.allow)
        }
    }

    /// Swap in the scriptlet for the page about to load.
    ///
    /// Only ever uses an engine that is already built — see `readyScriptlet` —
    /// so this can't turn a first-launch filter parse into a stalled navigation.
    @MainActor
    private func installScriptlet(for url: URL) async {
        let scriptlet = await AdblockEngineStore.shared.readyScriptlet(for: url.absoluteString)
        // Rebuilding the script set on every navigation would be wasted work when
        // the answer hasn't changed, which for most sites is "no scriptlet".
        guard scriptlet != currentScriptlet else { return }
        currentScriptlet = scriptlet
        WebViewFactory.installUserScripts(into: webView.configuration.userContentController,
                                          scriptlet: scriptlet)
    }

    /// A response the web view can't render — a PDF the server marks as an
    /// attachment, a zip, an installer — becomes a download instead of a blank
    /// page. `.download` hands the transfer to WebKit, which keeps the page's
    /// cookies and auth.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Only the main frame. Subframes serve all kinds of odd MIME types —
        // tracking pixels, ad iframes, media segments — and treating those as
        // downloads both spams the list and kills the page load underneath.
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }

        // Remember the status so `didFinish` can recognise an error page that
        // came with no content. Recorded rather than acted on here: plenty of
        // sites serve a perfectly good 404 page, and refusing to show it would be
        // worse than the blank page this exists to prevent.
        lastMainFrameStatus = (navigationResponse.response as? HTTPURLResponse)?.statusCode

        let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().contains("attachment") ?? false

        if !navigationResponse.canShowMIMEType || isAttachment {
            resetProgress()
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    /// WebKit created the download object — hand it to the manager, which owns
    /// the destination, progress and retry logic.
    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(
            download, suggestedName: navigationResponse.response.suggestedFilename)
        announceDownloadStarted()
    }

    /// A link with the `download` attribute starts life as a navigation.
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
        announceDownloadStarted()
    }

    /// Downloads are invisible while the page is up, so give a haptic and pop the
    /// start box open on Downloads — otherwise a tap on a file link looks like a
    /// dead link.
    private func announceDownloadStarted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showHome(animated: true)
        homeOverlay.showDownloads()
    }
}

// MARK: - WKUIDelegate (popup / new-window suppression)

extension BrowserViewController: WKUIDelegate {

    /// A live look at where a link goes, shown above its menu.
    ///
    /// Its own web view, and deliberately a bare one. Reusing the browser's
    /// configuration would register the history bridge and every other message
    /// handler against this controller, so merely *peeking* at a link would
    /// write it into history and report its media — a preview that changes the
    /// state of the app is not a preview.
    ///
    /// What it does keep is the two things a peek must not leak past: the
    /// profile's data store, so a preview in a private session stays in that
    /// session's memory, and the compiled blocking rules, so a page nobody has
    /// chosen to visit yet cannot load its trackers.
    private func linkPreview(for url: URL) -> UIViewController {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.websiteDataStore
        configuration.applicationNameForUserAgent =
            "Version/17.0 Mobile/15E148 Safari/604.1"
        configuration.defaultWebpagePreferences.allowsContentJavaScript = !Settings.blockJavaScript
        configuration.allowsInlineMediaPlayback = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let preview = WKWebView(frame: .zero, configuration: configuration)
        preview.isOpaque = false
        preview.backgroundColor = .systemBackground

        let controller = UIViewController()
        controller.view = preview
        // Smaller than the system's default, which fills most of the screen —
        // at that size the preview stops being a glance at a link and becomes a
        // page you are reading, with the menu pushed off underneath it. Two
        // thirds of the width, and taller than wide so it still reads as a page.
        let width = view.bounds.width * 0.62
        controller.preferredContentSize = CGSize(width: width, height: width * 1.35)

        // The rules are compiled asynchronously and the preview is on screen
        // immediately, so this loads once they are attached rather than racing
        // them — a second or two of blank preview beats a preview full of ads.
        Task { @MainActor in
            await ContentBlocker.apply(level: Settings.blockingLevel, to: preview)
            preview.load(pageRequest(url))
        }
        return controller
    }

    /// Tapping the preview itself opens the link, which is what a preview is
    /// for. The same tab, since this is following a link rather than starting
    /// somewhere new.
    func webView(_ webView: WKWebView,
                 contextMenuForElement elementInfo: WKContextMenuElementInfo,
                 willCommitWithAnimator animator: UIContextMenuInteractionCommitAnimating) {
        guard let url = elementInfo.linkURL, url.isWebPage else { return }
        animator.addCompletion { [weak self] in
            guard let self else { return }
            self.webView.load(self.pageRequest(url))
        }
    }

    /// The menu shown by pressing and holding a link.
    ///
    /// Without this WebKit supplies its own, and its own has no idea this app
    /// has tabs — so the one thing a long press on a link is *for* was missing,
    /// and the way out of the page it offered was Safari. Supplying a
    /// configuration replaces that menu wholesale.
    ///
    /// Only links get one. A press on an image or on plain text falls through
    /// to WebKit by returning nil, which leaves selection, Copy and the image
    /// actions exactly as they were.
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, url.isWebPage else {
            completionHandler(nil)
            return
        }

        let configuration = UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: Settings.showsLinkPreview
                ? { [weak self] in self?.linkPreview(for: url) }
                : nil
        ) { [weak self] _ in
            guard let self else { return nil }
            return UIMenu(children: [
                UIAction(title: "Open",
                         image: UIImage(systemName: "arrow.up.right.square")) { [weak self] _ in
                    guard let self else { return }
                    // The same tab, so this counts as following a link rather
                    // than as starting somewhere new — the visit chain holds.
                    self.webView.load(self.pageRequest(url))
                },
                UIAction(title: "Open in New Tab",
                         image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    // Descended from the page it was tapped on, so the chain is
                    // not reset.
                    self?.openTab(url: url, startsNewChain: false)
                },
                UIAction(title: "Open in New Private Tab",
                         image: UIImage(systemName: "hand.raised")) { [weak self] _ in
                    guard let self else { return }
                    // Private browsing here is a whole profile, not a per-tab
                    // flag — separate storage, separate history, separate web
                    // view. So this enters that mode and opens the link inside
                    // it, which is also what Safari does on iPhone. Already
                    // private, the switch is a no-op and only the tab is new.
                    //
                    // Through the same gate as the Private button: this is the
                    // other door into the mode, and a lock with a second way in
                    // is not a lock.
                    enterPrivateBrowsing { [weak self] in self?.openTab(url: url) }
                },
                UIAction(title: "Open in Background",
                         image: UIImage(systemName: "square.stack")) { [weak self] _ in
                    guard let self else { return }
                    // Queued without being switched to, which is the whole point
                    // of it — the reader keeps their place and collects links as
                    // they go.
                    stashSessionState()
                    tabManager.addTab(url: url, select: false)
                    homeOverlay.setTabs(tabs, current: currentTabID)
                },
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Copy Link",
                             image: UIImage(systemName: "doc.on.doc")) { _ in
                        UIPasteboard.general.url = url
                    },
                    UIAction(title: "Copy Clean Link",
                             image: UIImage(systemName: "sparkles")) { _ in
                        // The same page, minus the campaign tags and click ids
                        // that would otherwise follow whoever you send it to.
                        UIPasteboard.general.url = url.withoutTrackingParameters
                    },
                    UIAction(title: Settings.showsLinkPreview ? "Hide Preview" : "Show Preview",
                             image: UIImage(systemName: Settings.showsLinkPreview
                                            ? "eye.slash" : "eye")) { _ in
                        // Reads from the next long press onward — the menu now
                        // on screen was configured before this was tapped.
                        Settings.showsLinkPreview.toggle()
                    },
                    UIAction(title: "Share…",
                             image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                        guard let self else { return }
                        let share = UIActivityViewController(activityItems: [url],
                                                             applicationActivities: nil)
                        share.popoverPresentationController?.sourceView = self.webView
                        share.popoverPresentationController?.sourceRect =
                            CGRect(x: self.webView.bounds.midX, y: self.webView.bounds.midY,
                                   width: 1, height: 1)
                        self.present(share, animated: true)
                    },
                ]),
            ])
        }
        completionHandler(configuration)
    }


    /// A page asking for a new window: `target="_blank"`, or `window.open`.
    ///
    /// This used to load every one of them straight into the current web view,
    /// under a comment claiming it dropped ad popups. It did the opposite —
    /// every `window.open` an ad script made became a full-page redirect, which
    /// is what made streaming sites unusable here and fine in other browsers.
    ///
    /// What replaces it has to keep the popups that matter. `window.open` is
    /// how a bank opens a statement, how card verification runs, and how a
    /// sign-in flow reaches its identity provider — refusing them all would
    /// break exactly the sites where breaking things is least acceptable.
    /// Filtering on `navigationType == .linkActivated` doesn't do it either:
    /// a popup opened from a click *handler* arrives as `.other`, so that test
    /// throws away real login flows and keeps nothing.
    ///
    /// Two things pass without question:
    ///
    /// 1. **Who it belongs to.** A pop-up to the site's own registrable domain
    ///    is that site's own flow — a statement, a receipt, a payment hand-off.
    /// 2. **Where it goes.** A sign-in provider is allowed on the strength of
    ///    the destination, which an ad redirect cannot fake: a domain on that
    ///    list is one whose operator would have to be complicit.
    ///
    /// Everything else is held, and what happens next is the user's to say. By
    /// default the browser asks — it names the destination on a plate with one
    /// button, and opens it if that button is tapped. With "Always block
    /// pop-ups" on it refuses outright and says so. Note what is *not* used
    /// here: a user-gesture test, which WebKit has already applied
    /// (`javaScriptCanOpenWindowsAutomatically` is false, so nothing untouched
    /// reaches this method) and which proves nothing anyway, since a
    /// click-hijack fires inside your tap on *play*.
    ///
    /// Whatever gets through becomes a **new tab**, except a sign-in, which
    /// gets a window of its own. A sign-in is the one case that needs the page
    /// behind it left running: it has to post the result back to its opener,
    /// and an opener whose web view has been taken away cannot receive it.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame == nil,
              url.isWebPage else { return nil }

        // The site's own pop-up — a statement, a receipt, a verification step.
        let sameSite = webView.url.map { !RequestParty.isThirdParty(url: url, sourceURL: $0) } ?? false

        // Signing in is the cross-site pop-up that has to work.
        //
        // "Continue with Google" opens `accounts.google.com` and waits for it
        // to hand a token back through `window.opener`. The same shape of flow
        // is how Apple, Microsoft, GitHub and every SSO provider works, so it
        // can't be special-cased to one domain. These are allowed on the
        // strength of *where they go*, which an ad redirect cannot fake: a
        // domain on that list is one whose operator would have to be complicit.
        let signIn = Self.isSignInProvider(url)

        // Everything that is neither of those has to be decided on.
        if !sameSite && !signIn {
            guard !Settings.blockRedirectPages else {
                // Asked and answered, in Settings. Say it happened; offer
                // nothing, because the user already said what they wanted.
                log("[Nav] pop-up blocked: \(url.host ?? url.absoluteString)")
                showPopupNotice(destination: nil, onOpen: nil)
                return nil
            }
            // The default: hold it, and ask.
            //
            // Returning nil is the only honest answer to give the page here.
            // WebKit wants a web view back synchronously and the decision has
            // not been made yet, so `window.open` reports the window refused —
            // which it was. Accepting it now and closing it if the user says no
            // would mean loading the page in order to ask whether to load it.
            //
            // The cost is the opener: opened from the notice, the new tab has
            // no `window.opener` back to the page that asked. Sign-ins are the
            // one flow that depends on that, and they never reach here.
            let opener = webView.url?.host
            guard opener.map(popupAllowedHosts.contains) == true else {
                log("[Nav] pop-up held: \(url.host ?? url.absoluteString)")
                showPopupNotice(destination: url.host) { [weak self] in
                    guard let self else { return }
                    if let opener { popupAllowedHosts.insert(opener) }
                    openTab(url: url)
                }
                return nil
            }
        }

        // Everything but a sign-in becomes a tab.
        //
        // Still a real web view, returned synchronously from the configuration
        // WebKit supplied — returning nil instead tells the page its window was
        // refused, and these pages check. The difference is where it goes: the
        // browser adopts it as its current tab rather than presenting it as a
        // sheet over the page behind.
        guard signIn else {
            let adopted = WKWebView(frame: view.bounds, configuration: configuration)
            adoptPopupAsTab(adopted, url: url)
            return adopted
        }

        // A real window, returned synchronously, built from WebKit's own
        // configuration. Anything else — loading the URL in this view, opening
        // a tab, returning nil — leaves the opener relationship unmade, and
        // that relationship is the entire mechanism a sign-in depends on. See
        // `PopupWindowController`.
        let popup = PopupWindowController(configuration: configuration)
        popup.webView.uiDelegate = self          // so `window.close()` reaches us
        // Closes itself once the download it exists to start has started.
        popup.onDownloadStarted = { [weak self] in
            guard let self else { return }
            announceDownloadStarted()
            popupWindow?.dismiss(animated: true)
            popupWindow = nil
        }
        popup.modalPresentationStyle = .automatic
        popupWindow = popup
        present(popup, animated: true)
        return popup.webView
    }

    /// The pop-up called `window.close()` — the last thing a sign-in callback
    /// does once it has handed the token back.
    func webViewDidClose(_ webView: WKWebView) {
        guard let popupWindow, popupWindow.webView === webView else { return }
        popupWindow.dismiss(animated: true)
        self.popupWindow = nil
    }
}

// MARK: - Injected script bridges

extension BrowserViewController: WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        if message.name == WebViewFactory.mediaHandler {
            handleMediaMessage(body)
            return
        }

        if message.name == WebViewFactory.scrollContextHandler {
            touchIsOnScrollableElement = body["scrollable"] as? Bool ?? false
            touchIsOnMedia = body["media"] as? Bool ?? false
            return
        }

        guard message.name == WebViewFactory.historyHandler,
              let href = body["url"] as? String,
              let url = URL(string: href) else { return }

        // Back/forward inside an SPA is still back/forward — it ranks lower than
        // a page you chose to open. A `replaceState` wasn't a page the user
        // asked for either, so it ranks with redirects rather than with real
        // route changes; it still records as its own visit.
        let transition: VisitTransition
        switch body["kind"] as? String {
        case "pop":     transition = .backForward
        case "replace": transition = .redirect
        default:        transition = .sameDocument
        }
        recordSameDocumentVisit(url: url, transition: transition)
        refreshBlockingForSameDocument(url: url)
    }

    /// Re-apply the URL-scoped blocking layers after a route change inside the
    /// current document.
    ///
    /// `decidePolicyFor` never sees these navigations — no document is loaded —
    /// so neither the document-start scriptlet nor the cosmetic script's one-time
    /// lookup would ever run again. On a single-page app that means every route
    /// after the first keeps the first one's rules.
    ///
    /// The other two layers need nothing here: content rule lists are applied by
    /// WebKit per request, and the fetch/XHR wrappers live in the page's context
    /// and read `location.href` when they're called.
    private func refreshBlockingForSameDocument(url: URL) {
        guard Settings.blockingLevel != .off else { return }

        // The cosmetic script owns its own state, so it is asked to re-query
        // rather than having selectors pushed at it. Its world, not the page's.
        if let encoded = try? JSONEncoder().encode(url.absoluteString),
           let literal = String(data: encoded, encoding: .utf8) {
            webView.evaluateJavaScript(
                "window.__mbCosmeticRefresh && window.__mbCosmeticRefresh(\(literal))",
                in: nil, in: .defaultClient)
        }

        Task { @MainActor [weak self] in
            guard let self,
                  let scriptlet = await AdblockEngineStore.shared
                      .readyScriptlet(for: url.absoluteString) else { return }
            // Already covering this document, either as the document-start user
            // script or from an earlier route change.
            guard scriptlet != self.currentScriptlet,
                  scriptlet != self.sameDocumentScriptlet else { return }
            self.sameDocumentScriptlet = scriptlet
            // Direct evaluation is the only option: a user script needs a
            // document to be injected into and there isn't a new one. Later than
            // document start, so a scriptlet that has to pre-empt the page's own
            // code won't — but the page's code for this route has usually not run
            // yet either, since the route change is what triggers it.
            self.webView.evaluateJavaScript(scriptlet, in: nil, in: .page)
        }
    }
}

// MARK: - TabManagerDelegate

extension BrowserViewController: TabManagerDelegate {

    /// The list changed — repaint whatever is showing it.
    func tabManagerDidChangeTabs(_ manager: TabManager) {
        homeOverlay.setTabs(manager.tabs, current: manager.selectedTabID)
    }

    /// A different tab became current: put it on screen. Selection is the single
    /// place that drives the web view, so add/select/close all route through here
    /// instead of each loading pages themselves.
    func tabManager(_ manager: TabManager, didSelect tab: Tab?, previous: Tab?) {
        guard let tab else {
            // Last tab closed — nothing to show but the start box.
            hasLoadedPage = false
            addressCapsule.isHidden = true
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            showHome(animated: true)
            return
        }
        hasLoadedPage = true
        guard !adoptingPopup else { return }
        load(tab)
    }
}

// MARK: - UIDocumentInteractionControllerDelegate

extension BrowserViewController: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController) -> UIViewController { self }

    func documentInteractionControllerDidEndPreview(_ controller: UIDocumentInteractionController) {
        documentPreview = nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension BrowserViewController: UIGestureRecognizerDelegate {
    // Only trigger the reveal swipe when the page is scrolled to the very top,
    // so normal in-page scrolling isn't hijacked.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard hasLoadedPage else { return false }
        let sv = webView.scrollView

        // "At the very top" accounting for the safe-area content inset. The
        // original condition, and on a plain document it is enough on its own.
        guard sv.contentOffset.y <= -sv.adjustedContentInset.top + 1 else { return false }

        // Not while the page is still moving. A flick that scrolls to the top
        // and keeps coasting leaves the offset at zero with the finger still
        // down, and the next downward movement — part of the same scroll, as
        // far as the person doing it is concerned — was opening the start box.
        guard !sv.isDecelerating, !sv.isDragging else { return false }

        // Not mid-pinch, where a two-finger movement has a downward component
        // roughly always.
        guard !sv.isZooming, !sv.isZoomBouncing else { return false }

        // Not when the finger landed on something the *page* scrolls.
        //
        // This is the one that made the gesture feel broken on "some sites"
        // and not others. A page whose content lives in its own scrolling
        // element — a feed in a fixed-height pane, a sidebar, a chat log —
        // leaves the web view's own scroll view parked at zero no matter how
        // far you scroll inside it. Every check above is therefore satisfied,
        // on every downward drag, forever. WebKit scrolls those elements
        // internally and reports nothing about them natively, so the only
        // thing that knows is the page: `scrollableTouch` is set from a
        // `touchstart` handler that walks up from whatever was touched looking
        // for a scrollable ancestor that isn't already at its top.
        guard !touchIsOnScrollableElement else { return false }

        // Not on a video player. A player wants downward drags for its own
        // ends — scrubbing, minimising, the site's own dismiss — and taking
        // them to open the start box is what made watching anything annoying.
        // Hit-tested by rectangle on the page side, so the controls drawn over
        // a player count as the player.
        guard !touchIsOnMedia else { return false }

        // Started near the top of the page.
        //
        // Everything above is about what the touch landed on; this is about
        // where. Restricting the reveal to a band means a downward drag lower
        // down belongs to the page no matter what it is — a carousel, a map, a
        // canvas, something with no scroll view and no way to announce itself.
        //
        // The band deliberately starts below the safe area rather than at the
        // screen edge. iOS owns the top edge for Notification Centre and
        // Control Center, and a gesture starting there is either eaten or has
        // to be taken away from the user, which is not a trade a browser should
        // make.
        let start = gestureRecognizer.location(in: view).y
        let top = view.safeAreaInsets.top
        guard start >= top, start <= top + Self.revealBandHeight else { return false }

        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Color helpers

private extension UIColor {
    /// Perceived brightness (0 dark … 1 light); nil if the color has no RGB
    /// representation. Used to pick a legible status-bar style.
    var luminance: CGFloat? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}

private extension String {
    /// `HTTPURLResponse.localizedString(forStatusCode:)` returns lowercase text
    /// ("not found"), which reads wrong as a sentence on the error page.
    func capitalizingFirstLetter() -> String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
