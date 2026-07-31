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
    private var themeColorObs: NSKeyValueObservation?
    private var underPageObs: NSKeyValueObservation?
    private var currentTopColor: UIColor?
    private let homeOverlay = HomeOverlayView()
    private let progressBar = UIProgressView(progressViewStyle: .bar)
    private var progressObservation: NSKeyValueObservation?
    private var hasLoadedPage = false

    // Tabs live as a list in the start box; one web view is reused.
    private var tabs: [Tab] = []
    private var currentTabID: UUID?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureAudioSession()
        setupWebView()
        setupProgressBar()
        setupHomeOverlay()
        setupGestures()
        restoreSession()
    }

    /// Restore persisted tabs; load the last-current tab, else show the start box.
    private func restoreSession() {
        let saved = SessionStore.load()
        tabs = saved.tabs
        currentTabID = saved.current
        if let id = currentTabID, let tab = tabs.first(where: { $0.id == id }) {
            hasLoadedPage = true
            webView.load(URLRequest(url: tab.url))
        } else {
            showHome(animated: false)
        }
    }

    private func persistSession() {
        SessionStore.save(tabs: tabs, current: currentTabID)
    }

    private func closeAllTabs() {
        tabs.removeAll()
        currentTabID = nil
        hasLoadedPage = false
        persistSession()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        homeOverlay.setTabs(tabs, current: currentTabID)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        guard let lum = currentTopColor?.luminance else { return .default }
        return lum > 0.6 ? .darkContent : .lightContent
    }

    /// Compliant background audio: use the official `AVAudioSession` playback
    /// category so user-initiated media (a tapped play button) keeps playing when
    /// the app is backgrounded or the screen locks — paired with
    /// UIBackgroundModes=audio. No site scripts are modified; a page that pauses
    /// itself on background is left to do so. This is capability, not tampering.
    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            print("[Audio] session setup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Setup

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Block JS-initiated popups (a major source of ad windows/tabs).
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Disable pinch-to-zoom on every site by forcing a non-scalable viewport.
        let noZoom = """
        var m = document.querySelector('meta[name=viewport]');
        if (!m) { m = document.createElement('meta'); m.name = 'viewport';
                  document.head.appendChild(m); }
        m.setAttribute('content',
          'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');
        """
        config.userContentController.addUserScript(
            WKUserScript(source: noZoom, injectionTime: .atDocumentEnd, forMainFrameOnly: true))

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.allowsBackForwardNavigationGestures = true   // native edge-swipe = back/forward
        webView.navigationDelegate = self
        webView.uiDelegate = self
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

    private func setupProgressBar() {
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.trackTintColor = .clear
        progressBar.progressTintColor = .systemBlue
        progressBar.alpha = 0
        view.addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2.5),
        ])
    }

    private func setupHomeOverlay() {
        homeOverlay.translatesAutoresizingMaskIntoConstraints = false
        homeOverlay.onSubmit = { [weak self] text in self?.handleSubmit(text) }
        homeOverlay.onDismiss = { [weak self] in self?.hideHome() }
        homeOverlay.onSelectTab = { [weak self] id in self?.switchToTab(id) }
        homeOverlay.onCloseTab = { [weak self] id in self?.closeTab(id) }
        // The history / settings panels are glass cards inside the overlay itself.
        homeOverlay.panel.onOpenURL = { [weak self] url in self?.openTab(url: url) }
        homeOverlay.panel.onCloseAllTabs = { [weak self] in self?.closeAllTabs() }
        homeOverlay.panel.onClearWebsiteData = {
            let store = WKWebsiteDataStore.default()
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

    private func setupGestures() {
        // Swipe down anywhere -> reveal the start box to type a new address.
        let revealSwipe = UISwipeGestureRecognizer(target: self, action: #selector(revealHome))
        revealSwipe.direction = .down
        revealSwipe.delegate = self
        webView.addGestureRecognizer(revealSwipe)
    }

    // MARK: - Home overlay

    private func showHome(animated: Bool) {
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: animated)
    }

    @objc private func revealHome() {
        homeOverlay.setTabs(tabs, current: currentTabID)
        homeOverlay.present(over: hasLoadedPage, animated: true)
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
          return location.origin+"/favicon.ico";
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self, let str = result as? String, let iconURL = URL(string: str) else { return }
            URLSession.shared.dataTask(with: iconURL) { data, _, _ in
                guard let data, let image = UIImage(data: data) else { return }  // .ico may not decode
                DispatchQueue.main.async {
                    guard let idx = self.tabs.firstIndex(where: { $0.id == id }) else { return }
                    self.tabs[idx].icon = image
                    self.homeOverlay.setTabs(self.tabs, current: self.currentTabID)
                }
            }.resume()
        }
    }

    private func hideHome() {
        guard hasLoadedPage else { return }   // nothing behind to reveal yet
        homeOverlay.dismiss(animated: true)
    }

    // MARK: - Navigation

    private func handleSubmit(_ raw: String) {
        guard let url = URLResolver.resolve(raw) else { return }
        openTab(url: url)
    }

    /// Open a URL in a new tab and make it current.
    private func openTab(url: URL) {
        let tab = Tab(title: url.host ?? url.absoluteString, url: url)
        tabs.append(tab)
        currentTabID = tab.id
        hasLoadedPage = true
        persistSession()
        homeOverlay.dismiss(animated: true)
        webView.load(URLRequest(url: url))
    }

    private func switchToTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        currentTabID = id
        hasLoadedPage = true
        persistSession()
        homeOverlay.dismiss(animated: true)
        if webView.url != tab.url { webView.load(URLRequest(url: tab.url)) }
    }

    private func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if currentTabID == id {
            currentTabID = tabs.last?.id
            if let tab = tabs.last {
                webView.load(URLRequest(url: tab.url))
            } else {
                hasLoadedPage = false
                webView.load(URLRequest(url: URL(string: "about:blank")!))
            }
        }
        persistSession()
        // Refresh the visible list in place (start box stays open).
        homeOverlay.setTabs(tabs, current: currentTabID)
    }

    private func updateProgress(_ value: Float) {
        if value < 1.0 {
            if progressBar.alpha == 0 {
                progressBar.setProgress(0, animated: false)
                UIView.animate(withDuration: 0.15) { self.progressBar.alpha = 1 }
            }
            progressBar.setProgress(value, animated: true)
        } else {
            progressBar.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.3, delay: 0.1) { self.progressBar.alpha = 0 }
        }
    }
}

// MARK: - WKNavigationDelegate

extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Keep the current tab's title/URL fresh for the list.
        guard let idx = tabs.firstIndex(where: { $0.id == currentTabID }) else { return }
        if let url = webView.url { tabs[idx].url = url }
        let pageTitle = webView.title ?? ""
        tabs[idx].title = pageTitle.isEmpty ? (webView.url?.host ?? tabs[idx].title) : pageTitle
        persistSession()
        // Record the visit in history.
        if let url = webView.url {
            HistoryStore.shared.record(url: url, title: tabs[idx].title)
        }
        // Pull the site's favicon for the tab row.
        fetchFavicon(for: tabs[idx].id)
    }

    // Refuse non-web schemes (itms-apps, market, tel, custom app schemes) so a
    // page can't bounce the browser into the App Store or another app.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow); return
        }
        let allowed: Set<String> = ["http", "https", "about", "data", "blob"]
        if let scheme = url.scheme?.lowercased(), !allowed.contains(scheme) {
            // itms-apps, market, tel, mailto, custom app schemes -> refuse.
            print("[Nav] blocked external scheme: \(scheme)")
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
}

// MARK: - WKUIDelegate (popup / new-window suppression)

extension BrowserViewController: WKUIDelegate {
    // A page asking to open a new window (target=_blank, window.open) returns nil:
    // no popup is created. Same-frame navigations still load normally in-place.
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           navigationAction.targetFrame == nil {
            // Load user-intended links in the existing view; drop ad popups.
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension BrowserViewController: UIGestureRecognizerDelegate {
    // Only trigger the reveal swipe when the page is scrolled to the very top,
    // so normal in-page scrolling isn't hijacked.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard hasLoadedPage else { return false }
        // "At the very top" accounting for the safe-area content inset.
        let sv = webView.scrollView
        return sv.contentOffset.y <= -sv.adjustedContentInset.top + 1
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
