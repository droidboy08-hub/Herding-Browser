import UIKit
import WebKit
import AVFoundation

/// Minimal, tab-less browser surface.
/// - One WKWebView, no tabs, no toolbar buttons.
/// - A centered "start box" (URL/search entry) floats in the middle of the frame.
/// - Navigation is gesture-driven: edge-swipe = back/forward (WKWebView native),
///   swipe-down = reveal the start box to enter a new address.
final class BrowserViewController: UIViewController {

    private var webView: WKWebView!
    private let topBar = UIView()   // solid, adapts to the site color
    private let refreshButton = UIView()            // host: holds the glass + progress ring
    /// Interactive glass: this is a button, and giving under the finger is half
    /// of what makes it read as one without a border or a fill.
    private let refreshGlass = GlassSurface.makeView(radius: 26, interactive: true)
    /// A menu glyph rather than a reload arrow: the button carries everything
    /// the browser can do to the page, and reload is one item in that list
    /// rather than the whole of it. Load progress is drawn by the ring around
    /// the button, so nothing is lost by the icon no longer being an arrow.
    ///
    /// SF Symbols has no vertical ellipsis — `ellipsis.vertical` names nothing,
    /// and asking for it returns nil and draws an empty button. So the
    /// horizontal one is turned on its side by `iconRotation`, which every
    /// transform applied to this view has to compose with rather than replace.
    private let refreshIcon = UIImageView(image: UIImage(systemName: "ellipsis"))
    private static let iconRotation = CGAffineTransform(rotationAngle: .pi / 2)
    /// Invisible, fills the glass circle. A `UIButton` rather than a tap
    /// recogniser because only a button can make a menu its *primary* action —
    /// which is what lets the same control open the menu on a tap in one mode
    /// and reload on a tap in the other.
    private let refreshHitButton = ExpandedHitButton(type: .system)
    private let progressRing = CAShapeLayer()       // page-load progress, drawn around the button
    /// Sweeps around the button while the button is held, arriving as the menu
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
    private var revealSwipe: UISwipeGestureRecognizer?
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
        setupRefreshButton()
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
        view.window?.overrideUserInterfaceStyle = Settings.darkMode ? .dark : .unspecified
        homeOverlay.reloadWallpaper()
        homeOverlay.reloadFavourites()
        homeOverlay.reloadStartBoxButtons()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
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
            guard let self, self.needsReloadOnForeground else { return }
            self.needsReloadOnForeground = false
            // Deferred recovery isn't a crash-loop symptom, so it doesn't count
            // against the retry budget — reset it and reload once.
            self.contentProcessCrashes = 0
            guard self.hasLoadedPage else { return }
            print("[Nav] foreground — reloading page lost to a jettisoned content process")
            self.reloadCurrentPage()
        }
    }

    deinit {
        for observer in [foregroundObserver, backgroundObserver, mediaSettingsObserver,
                         pageScriptsObserver, blockingObserver, appearanceObserver,
                         favouritesObserver].compactMap({ $0 }) {
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
            refreshButton.isHidden = Settings.startPage == .startBox
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
            print("[Nav] restored session painted nothing — reloading \(restored)")
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
            self?.stashSessionState()
            self?.profile.shutdown()
        }
    }

    private func closeAllTabs() {
        tabManager.removeAllTabs()
        hasLoadedPage = false
        refreshButton.isHidden = true
        webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let lum = currentTopColor?.luminance else { return .default }
        return lum > 0.6 ? .darkContent : .lightContent
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
    private func installWebView() {
        // Privacy defaults, injected scripts and the history bridge all live in
        // WebViewFactory — see WebViewConfiguration.swift.
        let config = WebViewFactory.makeConfiguration(profile: profile, scriptDelegate: self)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true   // native edge-swipe = back/forward
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Retries start from the same web view, so they carry the page's cookies.
        DownloadManager.shared.webView = webView
        observeSameDocumentNavigations()
        // Full-bleed to the top edge; the scroll view auto-insets its content by
        // the safe area, so pages start below the Dynamic Island but their content
        // scrolls UNDER the top (revealing it through the frosted bar below).
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        // Hard fallback: kill the scroll view's own pinch-zoom recognizer.
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        webView.scrollView.bouncesZoom = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
        underPageObs = webView.observe(\.underPageBackgroundColor, options: [.new]) { [weak self] _, _ in
            self?.applyTopColor()
        }
    }

    private func applyTopColor() {
        let color = webView.themeColor ?? webView.underPageBackgroundColor
        currentTopColor = color
        UIView.animate(withDuration: 0.25) {
            // Plain solid bar in the site color.
            self.topBar.backgroundColor = color ?? .systemBackground
        }
        setNeedsStatusBarAppearanceUpdate()
    }

    /// Floating glass refresh button, bottom-right over the page. Tap reloads,
    /// long-press hard-reloads ignoring cache. Page-load progress draws as a ring
    /// around it (there is no top progress bar).
    private func setupRefreshButton() {
        let size: CGFloat = 52
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.layer.masksToBounds = false          // ring must not clip
        GlassSurface.applyFallbackShadow(to: refreshButton, opacity: 0.18, radius: 12,
                                         offset: CGSize(width: 0, height: 5))
        view.addSubview(refreshButton)

        // Circular glass body.
        refreshGlass.translatesAutoresizingMaskIntoConstraints = false
        GlassSurface.applyFallbackEdge(to: refreshGlass,
                                       color: UIColor.white.withAlphaComponent(0.35).cgColor)
        refreshButton.addSubview(refreshGlass)

        refreshIcon.translatesAutoresizingMaskIntoConstraints = false
        refreshIcon.tintColor = .label
        refreshIcon.contentMode = .scaleAspectFit
        refreshIcon.transform = Self.iconRotation
        refreshIcon.accessibilityLabel = "Reload"
        refreshIcon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        refreshGlass.contentView.addSubview(refreshIcon)

        // Progress ring traces the squircle's outline as the page loads.
        progressRing.fillColor = UIColor.clear.cgColor
        progressRing.strokeColor = UIColor.tintColor.cgColor
        progressRing.lineWidth = 3
        progressRing.lineCap = .round
        progressRing.strokeEnd = 0
        progressRing.opacity = 0
        refreshButton.layer.addSublayer(progressRing)

        NSLayoutConstraint.activate([
            refreshButton.widthAnchor.constraint(equalToConstant: size),
            refreshButton.heightAnchor.constraint(equalToConstant: size),
            refreshButton.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -18),
            refreshButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            refreshGlass.topAnchor.constraint(equalTo: refreshButton.topAnchor),
            refreshGlass.bottomAnchor.constraint(equalTo: refreshButton.bottomAnchor),
            refreshGlass.leadingAnchor.constraint(equalTo: refreshButton.leadingAnchor),
            refreshGlass.trailingAnchor.constraint(equalTo: refreshButton.trailingAnchor),

            refreshIcon.centerXAnchor.constraint(equalTo: refreshGlass.contentView.centerXAnchor),
            refreshIcon.centerYAnchor.constraint(equalTo: refreshGlass.contentView.centerYAnchor),
        ])

        refreshButton.isHidden = true          // only meaningful once a page is loaded

        refreshHitButton.translatesAutoresizingMaskIntoConstraints = false
        refreshHitButton.backgroundColor = .clear
        // Tap reloads, press opens the menu.
        //
        // Both are UIKit's own: `UIControl.h` says a menu enables the control's
        // context-menu interaction, presented "on touch-down" when it is the
        // primary action and on a long press otherwise. Leaving
        // `showsMenuAsPrimaryAction` off is therefore what puts the menu on the
        // press — and it frees the tap, which the menu would otherwise consume.
        // This is the only split of the two that UIKit supports; the reverse
        // cannot work, because whichever gesture the menu takes is gone.
        refreshHitButton.showsMenuAsPrimaryAction = false
        refreshHitButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            tapFeedback.impactOccurred()
            spinRefreshIcon()
            webView.reload()
        }, for: .primaryActionTriggered)
        // The menu opening gets its own, heavier tick — the press has no other
        // confirmation until the menu actually appears.
        refreshHitButton.addAction(UIAction { [weak self] _ in
            self?.menuFeedback.impactOccurred()
        }, for: .menuActionTriggered)
        // Rebuilt every time it opens: the menu shows the current gesture mode
        // and disables what the current page can't do, so a menu captured once
        // would go stale the first time either changed.
        refreshHitButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.pageMenu().children ?? [])
            }
        ])
        refreshButton.addSubview(refreshHitButton)
        NSLayoutConstraint.activate([
            refreshHitButton.topAnchor.constraint(equalTo: refreshButton.topAnchor),
            refreshHitButton.bottomAnchor.constraint(equalTo: refreshButton.bottomAnchor),
            refreshHitButton.leadingAnchor.constraint(equalTo: refreshButton.leadingAnchor),
            refreshHitButton.trailingAnchor.constraint(equalTo: refreshButton.trailingAnchor),
        ])

    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Ring sits just outside the circular glass edge, starting at 12 o'clock.
        let b = refreshButton.bounds
        progressRing.frame = b
        progressRing.path = UIBezierPath(
            arcCenter: CGPoint(x: b.midX, y: b.midY),
            radius: b.width / 2 + progressRing.lineWidth,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true).cgPath
        if refreshButton.layer.shadowOpacity > 0 {
            refreshButton.layer.shadowPath = UIBezierPath(ovalIn: b).cgPath
        }
    }

    // MARK: - Long-press build-up

    /// Acknowledge a reload.
    ///
    /// A pulse rather than the spin this used to do: three dots turning through
    /// a full circle reads as a control that has broken, not as a page
    /// reloading. The reload itself is shown by the progress ring around the
    /// button, which is where it belonged all along.
    private func spinRefreshIcon() {
        UIView.animate(withDuration: 0.14, animations: {
            self.refreshIcon.transform = Self.iconRotation.scaledBy(x: 0.78, y: 0.78)
            self.refreshIcon.alpha = 0.5
        }, completion: { _ in
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.55,
                           initialSpringVelocity: 0.6, options: []) {
                self.refreshIcon.transform = Self.iconRotation
                self.refreshIcon.alpha = 1
            }
        })
    }

    // MARK: - Page menu

    /// Everything the browser can do to the page you're on.
    ///
    /// It hangs off the refresh button because that button is the only chrome
    /// on screen — there is no toolbar to put a menu button in, and inventing
    /// one would cost the thing that makes this browser what it is.
    private func pageMenu() -> UIMenu {
        let hasPage = hasLoadedPage && webView.url?.isWebPage == true

        // The gesture's behaviour, at the top, as a submenu showing its state.
        let current = Settings.swipeDownAction
        // No image of its own: a submenu already carries the system's chevron,
        // which turns as it opens. A second, static one beside it read as an
        // arrow that was supposed to do something and didn't.
        let gesture = UIMenu(
            title: "Swipe Down Gesture",
            subtitle: current.name,
            children: SwipeDownAction.allCases.map { action in
                UIAction(title: action.name,
                         state: action == current ? .on : .off) { [weak self] _ in
                    Settings.swipeDownAction = action
                    self?.configureSwipeDownBehaviour()
                }
            })

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
            self?.revealHome()
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
        spinRefreshIcon()
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
        share.popoverPresentationController?.sourceView = refreshButton
        share.popoverPresentationController?.sourceRect = refreshButton.bounds
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

    /// Say that a page was refused.
    ///
    /// A blocker this blunt has to be visible or it is indistinguishable from a
    /// broken site: a link that does nothing, silently, is the same experience
    /// as a bug. Told what happened, someone whose bank really did need that
    /// window knows which switch to reach for.
    ///
    /// Sits above the page and below the refresh button, and is not tappable —
    /// it interrupts nothing.
    private func showRedirectBlockedNotice() {
        let plate = GlassSurface.makeView(radius: 18, fallback: .systemThickMaterial)
        plate.translatesAutoresizingMaskIntoConstraints = false
        plate.isUserInteractionEnabled = false
        plate.alpha = 0

        let label = UILabel()
        label.text = "Redirect blocked"
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .label
        label.translatesAutoresizingMaskIntoConstraints = false
        plate.contentView.addSubview(label)

        view.addSubview(plate)
        view.bringSubviewToFront(refreshButton)
        NSLayoutConstraint.activate([
            plate.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            plate.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor,
                                          constant: -24),
            plate.heightAnchor.constraint(equalToConstant: 38),
            label.leadingAnchor.constraint(equalTo: plate.contentView.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: plate.contentView.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: plate.contentView.centerYAnchor),
        ])

        plate.transform = CGAffineTransform(translationX: 0, y: 10)
        UIView.animate(springDuration: 0.4, bounce: 0.2) {
            plate.alpha = 1
            plate.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 1.6, options: [.curveEaseIn]) {
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
                Swift.print("[Print] failed: \(error.localizedDescription)")
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
            setPrivateBrowsing(on)
            // Reflect what actually happened, rather than letting the button
            // assume the switch went through.
            homeOverlay.panel.isPrivateBrowsing = profile.isPrivate
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
        homeOverlay.panel.onShowLicences = { [weak self] in
            guard let self else { return }
            let licences = LicencesViewController()
            present(UINavigationController(rootViewController: licences), animated: true)
        }
        homeOverlay.onDismissed = { [weak self] in
            guard let self, reloadWhenOverlayCloses else { return }
            reloadWhenOverlayCloses = false
            guard hasLoadedPage, webView.url != nil else { return }
            webView.reload()
        }
        homeOverlay.panel.onOpenSupport = { [weak self] destination in
            guard let self else { return }
            switch destination {
            case .help:
                guard let url = URL(string: SupportInfo.supportURL) else { return }
                openTab(url: url)
            case .feedback:
                guard let url = SupportInfo.feedbackURL(subject: "Feedback") else { return }
                UIApplication.shared.open(url)
            case .siteProblem:
                // The address of the page being complained about, and nothing
                // else about the session.
                let site = webView.url?.absoluteString ?? "no page open"
                guard let url = SupportInfo.feedbackURL(subject: "Site problem: \(site)") else { return }
                UIApplication.shared.open(url)
            }
        }
        homeOverlay.panel.onConfirmDestructive = { [weak self] title, consequence, act in
            guard let self else { return }
            let alert = UIAlertController(title: title, message: consequence,
                                          preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: title, style: .destructive) { _ in act() })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            // iPad presents an action sheet as a popover and insists on knowing
            // what it is popping out of.
            alert.popoverPresentationController?.sourceView = homeOverlay.panel
            alert.popoverPresentationController?.sourceRect = homeOverlay.panel.bounds
            present(alert, animated: true)
        }
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
        refreshButton.isHidden = true
    }

    /// Replace the web view with one built for the current profile, keeping the
    /// chrome that sits around it.
    private func rebuildWebView() {
        // Drop every observation first: they hold the old web view, and a KVO
        // callback arriving mid-swap would apply the old page's state to the new
        // one.
        progressObservation = nil
        themeColorObs = nil
        underPageObs = nil
        urlObservation = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()

        installWebView()
        // The web view is added on top of everything; put the chrome back in
        // front of it.
        view.bringSubviewToFront(topBar)
        view.bringSubviewToFront(refreshButton)
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
    private func presentPasswordsInfo() {
        let alert = UIAlertController(
            title: "Passwords",
            message: "Saved passwords come from iOS — iCloud Keychain, or whichever "
                   + "password manager you use. They fill into sign-in forms straight "
                   + "from the keyboard, and this browser never sees or stores them.\n\n"
                   + "Manage them in Settings › General › AutoFill & Passwords.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
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
        // Swipe down anywhere -> reveal the start box to type a new address.
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(revealHome))
        swipe.direction = .down
        swipe.delegate = self
        webView.addGestureRecognizer(swipe)
        revealSwipe = swipe
        configureSwipeDownBehaviour()
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
        let wantsReload = Settings.swipeDownAction == .reloadPage
        revealSwipe?.isEnabled = !wantsReload
        updateRefreshButtonAction()

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

    /// What a tap on the refresh button does, which follows from what the drag
    /// does.
    ///
    /// With the drag set to reload, the button's old job is taken — so a tap
    /// opens the menu, and reloading stays where the user just put it. With the
    /// drag revealing the start box, the button is the only way to reload, so a
    /// tap reloads and the menu moves to a long press. Either way both actions
    /// are one gesture away, and neither is behind the same gesture twice.
    private func updateRefreshButtonAction() {
        // Nothing to switch: the menu is the tap in both swipe modes, and the
        // press reloads. Both are driven from the button's own touches — see
        // `setupRefreshButton` — so the flag UIKit would use stays off. Setting
        // it here is what broke the press: it made UIKit open the menu on touch
        // down and cancel the touch the hold was being timed from.
    }

    @objc private func pullToRefreshFired() {
        // Committed at this point, so it gets the same acknowledgement a
        // deliberate reload gets: a tick you can feel and the button spinning,
        // on top of the control's own spinner.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        refreshButton.isHidden = !hasLoadedPage
        spinRefreshIcon()
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
        refreshButton.isHidden = true
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: animated)
    }

    @objc private func revealHome() {
        refreshButton.isHidden = true
        // Snapshot the page we're leaving so its grid card shows a live preview.
        captureSnapshot { [weak self] in
            guard let self else { return }
            self.homeOverlay.setTabs(self.tabs, current: self.currentTabID)
        }
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: true)
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
    private static let faviconSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    private func hideHome() {
        guard hasLoadedPage else { return }   // nothing behind to reveal yet
        homeOverlay.dismiss(animated: true)
        // Dismissing the start box puts a live page back on screen, so the
        // refresh button belongs there again. Without this it stayed hidden
        // until the next tab load.
        refreshButton.isHidden = false
    }

    // MARK: - Navigation

    private func handleSubmit(_ raw: String) {
        guard let url = URLResolver.resolve(raw) else { return }
        // Typed URLs and searches are the strongest signal of intent, and rank
        // highest — but WebKit reports them as `.other`, so flag it here.
        nextNavigationIsTyped = true
        openTab(url: url)
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
        refreshButton.isHidden = false
        tabManager.addTab(url: url)      // selection callback loads it
    }

    private func switchToTab(_ id: UUID) {
        guard id != currentTabID else {
            homeOverlay.dismiss(animated: true)
            refreshButton.isHidden = false
            return
        }
        stashSessionState()
        hasLoadedPage = true
        homeOverlay.dismiss(animated: true)
        refreshButton.isHidden = false
        tabManager.selectTab(id: id)     // selection callback loads it
    }

    private func closeTab(_ id: UUID) {
        tabManager.removeTab(id: id)     // selection callback loads the neighbour
    }

    /// Drive the ring from the web view's real load progress.
    ///
    /// `strokeEnd` is animated explicitly (implicit CA animations lag behind the
    /// actual value and make the ring look wrong), and any previous fade is
    /// removed first — a left-over non-removed fade would pin the layer
    /// invisible for every subsequent load.
    private func updateProgress(_ value: Float) {
        progressRing.removeAnimation(forKey: "fade")

        if value < 1.0 {
            progressRing.opacity = 1
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            progressRing.strokeEnd = CGFloat(max(0.02, value))   // always show a sliver
            CATransaction.commit()
        } else {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.15)
            progressRing.strokeEnd = 1
            CATransaction.commit()
            fadeOutRing(after: 0.15)
        }
    }

    /// Fade the ring away and reset it so the next load starts from zero.
    private func fadeOutRing(after delay: TimeInterval) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.3
        fade.beginTime = CACurrentMediaTime() + delay
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = true
        progressRing.add(fade, forKey: "fade")
        progressRing.opacity = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.3) { [weak self] in
            guard let self, self.progressRing.opacity == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.progressRing.strokeEnd = 0
            CATransaction.commit()
        }
    }

    /// Cancel any in-flight progress display (failed or cancelled navigation).
    private func resetProgress() {
        progressRing.removeAnimation(forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressRing.opacity = 0
        progressRing.strokeEnd = 0
        CATransaction.commit()
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // Show the ring immediately — estimatedProgress can lag the first bytes.
        progressRing.removeAnimation(forKey: "fade")
        progressRing.opacity = 1
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
        print("[Nav] load failed: \(ns.code) \(ns.localizedDescription)")
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
            print("[Nav] content process jettisoned while backgrounded — deferring reload")
            return
        }

        contentProcessCrashes += 1
        guard contentProcessCrashes <= maxCrashRecoveryAttempts else {
            // Reloading again would just crash again; stop and tell the user.
            print("[Nav] content process crashed \(contentProcessCrashes)× — giving up")
            showErrorPage(message: "This page used too much memory and stopped responding.")
            contentProcessCrashes = 0
            return
        }

        print("[Nav] content process terminated (attempt \(contentProcessCrashes)) — reloading")
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
            print("[Nav] \(status) with an empty body — showing an error page")
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
                print("[Nav] page finished but painted nothing — reloading \(url)")
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
                print("[Nav] blocked external scheme: \(scheme)")
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
    /// Three things separate a bank's popup from an ad's:
    ///
    /// 1. **A user gesture.** `javaScriptCanOpenWindowsAutomatically` is false,
    ///    so WebKit never calls this method for a popup nobody touched. Every
    ///    one that arrives here is gesture-backed — necessary, and nowhere near
    ///    sufficient, because a click-hijack fires inside your tap on *play*.
    /// 2. **Who it belongs to.** A popup to the site's own registrable domain
    ///    is that site's own flow. Allowed without further question.
    /// 3. **The filter lists.** Cross-site popups go to the ad-block engine,
    ///    which is what the lists are for — ad and redirect domains are what
    ///    they cover best. An identity provider isn't in them; a redirector is.
    ///
    /// Whatever survives opens as a **new tab** rather than replacing what you
    /// were reading. That is both what a popup means and what saves the case
    /// you're worried about: a bank's page stays loaded and logged in behind
    /// the window it opened.
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

        // With the redirect blocker off, a pop-up is a pop-up. With it on, only
        // the two cases above get through.
        guard sameSite || signIn || !Settings.blockRedirectPages else {
            print("[Nav] redirect blocked: \(url.host ?? url.absoluteString)")
            showRedirectBlockedNotice()
            return nil
        }

        // A real window, returned synchronously, built from WebKit's own
        // configuration. Anything else — loading the URL in this view, opening
        // a tab, returning nil — leaves the opener relationship unmade, and
        // that relationship is the entire mechanism a sign-in depends on. See
        // `PopupWindowController`.
        let popup = PopupWindowController(configuration: configuration)
        popup.webView.uiDelegate = self          // so `window.close()` reaches us
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
            refreshButton.isHidden = true
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            showHome(animated: true)
            return
        }
        hasLoadedPage = true
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
