import WebKit

/// `WKUserContentController` retains its message handlers strongly, and the web
/// view retains the controller. Registering a view controller directly builds a
/// cycle that outlives the screen; this forwards weakly instead.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        delegate?.userContentController(controller, didReceive: message)
    }
}

/// Builds the web view configuration: privacy defaults, injected user scripts and
/// the message handlers they report through.
///
/// Everything injected here is a local string literal compiled into the binary.
/// Nothing is fetched or evaluated from a remote source, which is what App Store
/// guideline 2.5.2 requires of an app that runs code.
enum WebViewFactory {

    /// Message handler name the history bridge posts to.
    static let historyHandler = "historyHandler"
    /// Message handler name the media-state reporter posts to.
    static let mediaHandler = "mediaHandler"
    /// Message handler name the scroll-context reporter posts to.
    static let scrollContextHandler = "scrollContextHandler"
    /// Message handler name the request-blocking script posts to.
    static let requestBlockingHandler = "requestBlockingHandler"
    /// Message handler name the cosmetic-filtering script posts to.
    static let cosmeticHandler = "cosmeticHandler"

    /// Shared secret between the injected scripts and their native handlers, new
    /// on every launch.
    ///
    /// The request-blocking script has to run in the page's own content world —
    /// it can only wrap `window.fetch` where the page will see it — which means
    /// the page can reach the message handler too. The token doesn't make that
    /// impossible, but it does mean a page can't cheaply probe the handler by
    /// guessing, and replaying a token from a previous launch is useless.
    static let securityToken = UUID().uuidString

    static func makeConfiguration(profile: Profile,
                                  scriptDelegate: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()

        // MARK: Storage
        // The profile decides where cookies, caches and local storage live:
        // `.default()` for a regular profile, `.nonPersistent()` for private
        // browsing, where none of it may outlive the session.
        config.websiteDataStore = profile.websiteDataStore

        // MARK: Privacy and safety
        // Try HTTPS first for hosts known to support it, so a typed bare host
        // doesn't make an initial cleartext request that a network observer sees.
        config.upgradeKnownHostsToHTTPS = true
        // Safe Browsing–style interstitial for known phishing and malware hosts.
        // On by default; set explicitly so a future edit can't silently drop it.
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        // Pages can't spawn windows on their own — the single largest source of
        // ad pop-ups and redirect chains.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Whether pages may run scripts at all. Off means the injected scripts
        // don't run either — but with no page scripts there is nothing for them
        // to intercept, and the compiled rule lists keep working regardless.
        config.defaultWebpagePreferences.allowsContentJavaScript = !Settings.blockJavaScript

        // Cross-site tracking prevention (ITP) is enforced by WebKit itself and
        // is on for both store types — there is no public switch to raise it
        // further. Blocking third-party cookies outright is only available
        // through a content-blocker ruleset, which is the Content Blocking work
        // still on the roadmap.

        // MARK: Media
        config.allowsInlineMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true

        // A bare WKWebView's user agent has no "Safari" token, so many sites
        // serve degraded or legacy markup. Presenting as mobile Safari is what
        // every third-party iOS browser does.
        config.applicationNameForUserAgent = "Version/17.0 Mobile/15E148 Safari/604.1"

        // MARK: User scripts
        // Handlers are registered once and only once — `add(_:name:)` throws on a
        // duplicate name. The scripts themselves are installed separately, so
        // they can be rebuilt when a setting changes.
        let controller = config.userContentController
        controller.add(WeakScriptMessageHandler(delegate: scriptDelegate), name: historyHandler)
        controller.add(WeakScriptMessageHandler(delegate: scriptDelegate), name: mediaHandler)
        controller.add(WeakScriptMessageHandler(delegate: scriptDelegate), name: scrollContextHandler)

        // Reply handlers, so the injected scripts get a promise back and can wait
        // for the verdict. These are retained by the controller and hold no
        // reference to any view controller, so no weak forwarding is needed.
        controller.addScriptMessageHandler(RequestBlockingHandler(),
                                           contentWorld: .page,
                                           name: requestBlockingHandler)
        controller.addScriptMessageHandler(CosmeticFilterHandler(),
                                           contentWorld: .defaultClient,
                                           name: cosmeticHandler)

        installUserScripts(into: controller)

        return config
    }

    /// Install the injected scripts for the current settings.
    ///
    /// Safe to call again after a setting changes: `WKUserContentController` has
    /// no way to remove one script, so the set is cleared and rebuilt. Scripts
    /// are injected per navigation, so a rebuild takes effect on the next page
    /// load rather than the current one.
    /// - Parameter scriptlet: JavaScript from a `+js(...)` filter rule that
    ///   applies to the page about to load, injected at document start.
    ///
    ///   Scriptlets exist to intercept a page's own code — replacing a constant,
    ///   aborting a script, patching an API — so running them after that code has
    ///   already run accomplishes nothing. Document start is the only useful
    ///   time, and a `WKUserScript` is the only way to inject there. Since user
    ///   scripts are fixed for the lifetime of a navigation, the caller rebuilds
    ///   the set while the next navigation is still pending.
    static func installUserScripts(into controller: WKUserContentController,
                                   scriptlet: String? = nil) {
        controller.removeAllUserScripts()

        if let scriptlet, !scriptlet.isEmpty {
            // Page world, or it can't touch what the page sees. Main frame only:
            // this scriptlet was selected for the top document's URL, and a
            // subframe on an unrelated origin must not run it. Subframes are
            // covered separately, at document end.
            controller.addUserScript(WKUserScript(source: scriptlet,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: true,
                                                  in: .page))
        }

        // Exactly one of these three owns the viewport, and which one it is has
        // to be decided here rather than by three scripts racing each other to
        // write the same meta tag.
        //
        // Desktop wins over the zoom setting: asking for the desktop site *is*
        // asking to be zoomed out, and a viewport pinned to `device-width`
        // would give the mobile layout back under a desktop user agent — which
        // is exactly the bug this replaced.
        if Settings.prefersDesktopSite {
            controller.addUserScript(WKUserScript(source: desktopViewport,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        } else if Settings.allowZoom {
            controller.addUserScript(WKUserScript(source: allowPinchZoom,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        } else {
            controller.addUserScript(WKUserScript(source: disablePinchZoom,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true))
        }
        // Before anything that wraps a built-in, and in the page's own world,
        // because it is the page-visible wrappers it exists to disguise.
        controller.addUserScript(WKUserScript(source: nativeFunctionMasking,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: .page))
        controller.addUserScript(WKUserScript(source: historyReporter,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        // Media state comes from every frame: embedded players (YouTube iframes,
        // podcast widgets) hold the media element, not the host document.
        controller.addUserScript(WKUserScript(source: mediaReporter,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        // Every frame: a feed inside an iframe scrolls exactly like one that
        // isn't, and the swipe has no way to tell them apart.
        controller.addUserScript(WKUserScript(source: scrollContextReporter,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false,
                                              in: .defaultClient))

        if Settings.blockingLevel != .off {
            // Page world, every frame, before the page's own scripts: `fetch`
            // has to be wrapped where the page will actually see it, and ad
            // requests come from iframes as often as the top document.
            controller.addUserScript(WKUserScript(source: requestBlocking,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false,
                                                  in: .page))
            // Isolated world: this one only reads the DOM and adds a stylesheet,
            // so there's no reason to expose it to the page.
            controller.addUserScript(WKUserScript(source: cosmeticFiltering,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: false,
                                                  in: .defaultClient))
        }

        if Settings.hideVideoTopBar {
            // Document end: the bar is drawn by the page's own code, so there
            // has to be a document to add a stylesheet to. Main frame only —
            // this is about the page you are looking at, not an embed inside it.
            controller.addUserScript(WKUserScript(source: hideVideoTopBar,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: true,
                                                  in: .defaultClient))
        }

        if Settings.preferHighestQuality {
            // Page world: this calls methods the site defines on its own player
            // element, and an isolated world can see the DOM but not those.
            // Every frame, because an embedded player is an iframe.
            controller.addUserScript(WKUserScript(source: highestQualityPlayback,
                                                  injectionTime: .atDocumentEnd,
                                                  forMainFrameOnly: false,
                                                  in: .page))
        }

        if Settings.blockFingerprinting {
            // Page world, every frame, at document start: the APIs have to be
            // replaced before any page script reads them, and a fingerprinting
            // script hidden in an iframe counts just the same.
            controller.addUserScript(WKUserScript(source: fingerprintProtection,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false,
                                                  in: .page))
        }

        if Settings.backgroundPlayback {
            // Every frame, and before the page's own scripts run — a player in an
            // iframe has to see the patched document too, and the property has to
            // be replaced before anything captures the original.
            controller.addUserScript(WKUserScript(source: mediaBackgrounding,
                                                  injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: false))
        }
    }

    // MARK: - Injected scripts

    /// Makes the wrappers installed below indistinguishable from the built-ins
    /// they replace, as far as `Function.prototype.toString` is concerned.
    ///
    /// This is what a failed Cloudflare "verify you are human" check actually
    /// was. A challenge does not only measure the browser — it checks whether
    /// anything has been *tampered with*, and the cheapest tamper test there is
    /// is to stringify a built-in and look for `[native code]`. Wrapping `fetch`
    /// or `getImageData` makes that test return the wrapper's own source, so the
    /// challenge concludes it is looking at an automated browser and fails it.
    /// Nothing about the wrappers' behaviour was ever the problem.
    ///
    /// So `toString` is taught to answer for the wrappers with the source of the
    /// function each one replaced. The replacement is registered as answering
    /// for *itself* too, or the disguise would be given away by the one function
    /// that performs it. `name` and `length` are copied across for the same
    /// reason: they are the other two properties a check like this reads.
    ///
    /// Runs before every other page-world script, and exposes `__mbMask` as a
    /// non-enumerable property so those scripts can reach it without it turning
    /// up in an enumeration of `window`.
    private static let nativeFunctionMasking = """
    (function() {
      if (window.__mbMask) { return; }

      var realToString = Function.prototype.toString;
      var sources = new WeakMap();

      function toString() {
        var source = sources.get(this);
        return source !== undefined ? source : realToString.call(this);
      }
      sources.set(toString, realToString.call(realToString));
      Function.prototype.toString = toString;

      function mask(wrapper, original) {
        try {
          sources.set(wrapper, realToString.call(original));
          ['name', 'length'].forEach(function(key) {
            var descriptor = Object.getOwnPropertyDescriptor(original, key);
            if (descriptor) { Object.defineProperty(wrapper, key, descriptor); }
          });
        } catch (e) {}
        return wrapper;
      }

      Object.defineProperty(window, '__mbMask', { value: mask });
    })();
    """

    /// Shared test: is this document a bot-check challenge or a captcha?
    ///
    /// Those frames exist to measure the browser, and every wrapper this file
    /// installs is something they are specifically looking for. There is nothing
    /// to gain by filtering them either — a captcha carries no ads and tracks
    /// nothing beyond the check it was put there to make — so the scripts that
    /// touch the page leave them alone entirely.
    ///
    /// Matched on host *and* path where the host is shared with something else:
    /// reCAPTCHA lives on `www.google.com`, and exempting all of Google Search
    /// from fingerprinting defence to accommodate it would be a poor trade.
    private static let challengeSurfaceTest = """
    function onChallengeSurface() {
      var host = location.hostname;
      var path = location.pathname;
      if (host === 'challenges.cloudflare.com') { return true; }
      if (host === 'hcaptcha.com' || host.endsWith('.hcaptcha.com')) { return true; }
      // Cloudflare's managed challenge serves its own scripts from the site's
      // origin under this path, so the host says nothing and the path says all.
      if (path.indexOf('/cdn-cgi/challenge-platform/') === 0) { return true; }
      if (path.indexOf('/recaptcha/') === 0) {
        if (host === 'www.google.com' || host === 'google.com' ||
            host === 'www.gstatic.com' || host === 'recaptcha.net' ||
            host === 'www.recaptcha.net') { return true; }
      }
      return false;
    }
    """

    /// Disable pinch-to-zoom site-wide by forcing a non-scalable viewport.
    /// Double-tap zoom and scrolling are untouched.
    private static let disablePinchZoom = """
    var m = document.querySelector('meta[name=viewport]');
    if (!m) { m = document.createElement('meta'); m.name = 'viewport';
              document.head.appendChild(m); }
    m.setAttribute('content',
      'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no');
    """

    /// Let every page be pinched, including the ones that say no.
    ///
    /// A site disables zoom by putting `user-scalable=no` or a `maximum-scale`
    /// of 1 in its own viewport tag. Those are stripped and replaced rather
    /// than the whole tag being rewritten, because the rest of what a site puts
    /// there — `width`, `viewport-fit=cover` for the notch — is its layout and
    /// is none of our business.
    private static let allowPinchZoom = """
    (function() {
      var m = document.querySelector('meta[name=viewport]');
      if (!m) { return; }   // no tag means the default, which already zooms
      var content = m.getAttribute('content') || '';
      content = content
        .replace(/user-scalable\\s*=\\s*(no|0)/gi, 'user-scalable=yes')
        .replace(/maximum-scale\\s*=\\s*[0-9.]+/gi, 'maximum-scale=10');
      if (!/user-scalable/i.test(content)) { content += ', user-scalable=yes'; }
      if (!/maximum-scale/i.test(content)) { content += ', maximum-scale=10'; }
      m.setAttribute('content', content);
    })();
    """

    /// The desktop layout, scaled to fit the screen.
    ///
    /// Asking WebKit for `preferredContentMode = .desktop` and a desktop user
    /// agent gets the desktop *markup*, but not the desktop *layout*: the
    /// viewport is still whatever the page asks for, and the page still asks
    /// for `device-width`. The result is a desktop stylesheet laid out in 400
    /// points, which is the wrong half of what was wanted.
    ///
    /// So the width is pinned to a desktop one and the initial scale set to
    /// whatever makes that width fit the screen. That is what "desktop site"
    /// looks like in every other browser: the whole page, small, and zoomable
    /// from there.
    ///
    /// Re-applied through an observer, because a site that writes its own
    /// viewport tag after load — most single-page apps do — would otherwise put
    /// the mobile layout straight back. `apply` is a no-op when the tag already
    /// says what it should, so the observer can't drive itself in a loop.
    private static let desktopViewport = """
    (function() {
      var WIDTH = 1280;   // wide enough for a desktop breakpoint, narrow enough to read

      function apply() {
        var m = document.querySelector('meta[name=viewport]');
        if (!m) {
          m = document.createElement('meta');
          m.name = 'viewport';
          (document.head || document.documentElement).appendChild(m);
        }
        // `screen.width` is the device width in CSS pixels at the default
        // scale, which is exactly the number the page has to be shrunk into.
        var available = window.screen.width || window.innerWidth || WIDTH;
        var scale = Math.min(1, available / WIDTH);
        var content = 'width=' + WIDTH
                    + ', initial-scale=' + scale.toFixed(4)
                    // Enough room below the fitted scale to pull back further,
                    // and well above it to read the small print.
                    + ', minimum-scale=' + (scale / 2).toFixed(4)
                    + ', maximum-scale=10, user-scalable=yes';
        if (m.getAttribute('content') === content) { return; }
        m.setAttribute('content', content);
      }

      apply();

      try {
        new MutationObserver(apply).observe(document.head || document.documentElement, {
          childList: true, subtree: true,
          attributes: true, attributeFilter: ['content', 'name']
        });
      } catch (e) {}
    })();
    """

    /// Same-document navigation reporter.
    ///
    /// A single-page app changes page by calling `history.pushState` — no
    /// navigation, no delegate callback, and if it pushes the same URL there
    /// isn't even a URL change to observe. Wrapping the History API is the only
    /// way to see every one of them.
    ///
    /// Runs at document start so it is in place before the page's own router.
    /// The original functions are called first, so page behaviour is unchanged
    /// whatever this does afterwards.
    private static let historyReporter = """
    (function() {
      function report(kind) {
        try {
          window.webkit.messageHandlers.\(historyHandler).postMessage({
            url: location.href, kind: kind
          });
        } catch (e) {}
      }
      var push = history.pushState;
      history.pushState = function() {
        push.apply(this, arguments);
        report('push');
      };
      var replace = history.replaceState;
      history.replaceState = function() {
        replace.apply(this, arguments);
        report('replace');
      };
      window.addEventListener('popstate', function() { report('pop'); });
      window.addEventListener('hashchange', function() { report('hash'); });
    })();
    """

    /// Media state reporter, so the lock screen knows what's playing.
    ///
    /// Media events (`play`, `pause`, `ended`) don't bubble, so the listeners are
    /// registered on the document in the capture phase — that reaches them
    /// without having to find and re-bind every element as pages add them.
    private static let mediaReporter = """
    (function() {
      function report(state, el) {
        if (!el || !el.tagName) { return; }
        var tag = el.tagName.toLowerCase();
        if (tag !== 'audio' && tag !== 'video') { return; }
        try {
          window.webkit.messageHandlers.\(mediaHandler).postMessage({
            state: state,
            title: document.title,
            duration: isFinite(el.duration) ? el.duration : null,
            time: el.currentTime
          });
        } catch (e) {}
      }
      document.addEventListener('play',  function(e) { report('play',  e.target); }, true);
      document.addEventListener('pause', function(e) { report('pause', e.target); }, true);
      document.addEventListener('ended', function(e) { report('ended', e.target); }, true);
    })();
    """

    /// Reports whether a touch landed inside something the page scrolls itself.
    ///
    /// The swipe-down gesture that reveals the start box is allowed only when
    /// the page is at its top — but on a site whose content lives in a
    /// scrolling *element* rather than in the document, the document is always
    /// at its top, and the gesture fired on every downward drag. WebKit
    /// scrolls those elements internally and exposes nothing about them to the
    /// native side, so the page has to say.
    ///
    /// Sent on `touchstart`, in the capture phase so a page that stops
    /// propagation on its own handlers can't suppress it, and passively so
    /// this can never delay a scroll. `scrollTop > 0` is the important part of
    /// the test: an element scrolled to its top *should* still let the gesture
    /// through, which is what makes a pull from the top of a feed work the way
    /// it does everywhere else.
    private static let scrollContextReporter = """
    (function() {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var bridge = handlers && handlers.\(scrollContextHandler);
      if (!bridge) { return; }

      function scrollableAncestor(node) {
        for (var el = node; el && el !== document.documentElement; el = el.parentElement) {
          if (!(el instanceof Element)) { continue; }
          if (el.scrollHeight - el.clientHeight <= 2) { continue; }
          var overflow = '';
          try { overflow = getComputedStyle(el).overflowY; } catch (e) { continue; }
          if (overflow !== 'auto' && overflow !== 'scroll' && overflow !== 'overlay') {
            continue;
          }
          // Already at its own top: a pull from here is a pull on the page.
          if (el.scrollTop <= 0) { continue; }
          return true;
        }
        return false;
      }

      // Did the touch land on a video player?
      //
      // Tested by rectangle rather than by walking up from the target, because
      // on a real player the target usually isn't the <video> at all — it's a
      // controls overlay stacked on top of it. Asking whether the point falls
      // inside a video's box catches the player and everything drawn over it.
      //
      // Videos too small to be watched are skipped: an autoplaying 1x1 or a
      // muted thumbnail preview is not something anyone is trying to touch, and
      // counting it would disable the gesture on pages that merely contain one.
      function onVideo(x, y) {
        var videos = document.querySelectorAll('video');
        for (var i = 0; i < videos.length; i++) {
          var box = videos[i].getBoundingClientRect();
          if (box.width < 80 || box.height < 60) { continue; }
          if (x >= box.left && x <= box.right && y >= box.top && y <= box.bottom) {
            return true;
          }
        }
        return false;
      }

      function report(scrollable, media) {
        try {
          bridge.postMessage({ scrollable: scrollable, media: media });
        } catch (e) {}
      }

      document.addEventListener('touchstart', function(event) {
        var target = event.target;
        var point = event.touches && event.touches[0];
        report(!!target && scrollableAncestor(target),
               !!point && onVideo(point.clientX, point.clientY));
      }, { capture: true, passive: true });

      // Cleared on release, so a stale "yes" from the last touch can't block
      // the next gesture.
      document.addEventListener('touchend', function() { report(false, false); },
                                { capture: true, passive: true });
      document.addEventListener('touchcancel', function() { report(false, false); },
                                { capture: true, passive: true });
    })();
    """

    /// Runtime request blocking for `fetch` and `XMLHttpRequest`.
    ///
    /// The compiled rule lists are the primary blocker and catch everything the
    /// markup asks for — images, scripts, frames. What they can't catch is a
    /// request a script builds at runtime with filter options WebKit's rule
    /// syntax cannot express. Those only become visible by wrapping the two APIs
    /// that make them.
    ///
    /// This is the one place where an injected script must run in the page's own
    /// content world: a wrapper installed in an isolated world would be invisible
    /// to the page's code. The originals are captured immediately at document
    /// start, before any page script can replace them.
    ///
    /// `postMessage` returns a promise here because the native side is registered
    /// as a `WKScriptMessageHandlerWithReply`, which is what lets a request wait
    /// for a verdict instead of racing it.
    ///
    /// Computed rather than stored, because it bakes in whether the current
    /// level matches first-party requests. That test used to happen natively,
    /// which meant every same-site request still paid for a full round trip to
    /// be told it was fine. Deciding it here costs a string compare and skips
    /// the bridge entirely — on most pages that is nearly every request.
    private static var requestBlocking: String {
        """
    (function() {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var bridge = handlers && handlers.\(requestBlockingHandler);
      if (!bridge) { return; }

      \(challengeSurfaceTest)
      if (onChallengeSurface()) { return; }

      var mask = window.__mbMask || function(wrapper) { return wrapper; };
      var TOKEN = '\(securityToken)';
      var BLOCKS_FIRST_PARTY = \(Settings.blockingLevel.blocksFirstParty);

      // The same registrable-domain approximation the native side uses, kept
      // deliberately coarse: it decides only whether to *skip* a check, and it
      // errs toward asking.
      var MULTI_SUFFIXES = {
        'co.uk':1,'org.uk':1,'ac.uk':1,'gov.uk':1,'co.jp':1,'or.jp':1,'ne.jp':1,
        'com.au':1,'net.au':1,'org.au':1,'co.nz':1,'com.br':1,'com.cn':1,
        'com.mx':1,'co.in':1,'co.za':1,'co.kr':1,'com.tr':1,'com.sg':1,'com.hk':1
      };
      function registrable(host) {
        var parts = String(host).toLowerCase().split('.');
        if (parts.length <= 2) { return parts.join('.'); }
        var lastTwo = parts.slice(-2).join('.');
        return parts.slice(MULTI_SUFFIXES[lastTwo] ? -3 : -2).join('.');
      }
      var PAGE_DOMAIN = registrable(location.hostname);

      // A challenge asking whether you are a human, wherever it is hosted. Never
      // delayed and never blocked, at any level: a page you cannot get past is
      // worse than any request it makes.
      function isChallenge(location) {
        var host = location.hostname;
        if (host === 'challenges.cloudflare.com') { return true; }
        if (host === 'hcaptcha.com' || host.endsWith('.hcaptcha.com')) { return true; }
        if (location.pathname.indexOf('/cdn-cgi/challenge-platform/') === 0) { return true; }
        if (location.pathname.indexOf('/recaptcha/') === 0) {
          if (host === 'www.google.com' || host === 'google.com' ||
              host === 'www.gstatic.com' || host === 'recaptcha.net' ||
              host === 'www.recaptcha.net') { return true; }
        }
        return false;
      }

      // A request this level would never block: don't ask, don't wrap it in a
      // promise, don't delay it by a single turn of the event loop.
      function skip(url) {
        var parsed;
        try { parsed = new URL(url); } catch (e) { return false; }
        if (isChallenge(parsed)) { return true; }
        if (BLOCKS_FIRST_PARTY) { return false; }
        return registrable(parsed.hostname) === PAGE_DOMAIN;
      }

      function ask(url, kind) {
        try {
          return bridge.postMessage({
            token: TOKEN, url: url, source: location.href, type: kind
          }).then(function(blocked) { return blocked === true; },
                  function() { return false; });
        } catch (e) {
          // Never let a bridge failure break the page — fail open.
          return Promise.resolve(false);
        }
      }

      function absolute(value) {
        try { return new URL(value, location.href).href; } catch (e) { return null; }
      }

      var realFetch = window.fetch;
      if (typeof realFetch === 'function') {
        window.fetch = mask(function fetch() {
          var args = arguments, self = this;
          var resource = args[0];
          var raw = typeof resource === 'string' ? resource
                  : (resource && typeof resource.url === 'string' ? resource.url : null);
          var url = raw === null ? null : absolute(raw);
          // Straight through, synchronously — not even a resolved promise, so
          // a first-party request is exactly as fast as it was unwrapped.
          if (url === null || skip(url)) { return realFetch.apply(self, args); }

          return ask(url, 'fetch').then(function(blocked) {
            if (blocked) {
              // The same rejection a network failure produces, so a page's own
              // error handling runs instead of it hanging.
              return Promise.reject(new TypeError('Load failed'));
            }
            return realFetch.apply(self, args);
          });
        }, realFetch);
      }

      var realOpen = XMLHttpRequest.prototype.open;
      var realSend = XMLHttpRequest.prototype.send;

      XMLHttpRequest.prototype.open = mask(function open(method, url, async) {
        // A synchronous request can't wait on a promise, so it is left alone.
        this.__blockCheckURL = (async === undefined || async) ? absolute(url) : null;
        return realOpen.apply(this, arguments);
      }, realOpen);

      XMLHttpRequest.prototype.send = mask(function send() {
        var self = this, args = arguments;
        var url = self.__blockCheckURL;
        // Same short-circuit as `fetch`, and it matters more here: a media
        // player streams its segments through XHR, and holding each one for a
        // native verdict is what made video slow to start and slow to resume.
        if (!url || skip(url)) { return realSend.apply(self, args); }

        ask(url, 'xmlhttprequest').then(function(blocked) {
          if (!blocked) { return realSend.apply(self, args); }
          // Report a network error rather than leaving the request pending
          // forever, which is what a blocked request should look like.
          try {
            self.dispatchEvent(new ProgressEvent('error'));
            self.dispatchEvent(new ProgressEvent('loadend'));
          } catch (e) {}
        });
      }, realSend);
    })();
    """
    }

    /// Cosmetic filtering: hides the elements that hold ads when the request
    /// itself couldn't be blocked.
    ///
    /// Two rounds, because the engine stores the two kinds of rule differently:
    ///
    /// 1. Rules written for this specific site, fetched by URL.
    /// 2. Generic rules (`##.ad-banner`, no domain). There are hundreds of
    ///    thousands of these, so the engine won't hand them over wholesale — the
    ///    page reports the classes and ids it actually contains and gets back
    ///    only the matching subset. A `$generichide` exception skips this round
    ///    entirely.
    ///
    /// Selectors are inserted in small batches inside try/catch: one malformed
    /// selector from a third-party list would otherwise throw away every rule
    /// batched with it.
    ///
    /// Runs in an isolated content world — it only reads the DOM and appends a
    /// stylesheet, so the page has no reason to see it.
    private static let cosmeticFiltering = """
    (function() {
      var handlers = window.webkit && window.webkit.messageHandlers;
      var bridge = handlers && handlers.\(cosmeticHandler);
      if (!bridge) { return; }

      \(challengeSurfaceTest)
      if (onChallengeSurface()) { return; }

      var TOKEN = '\(securityToken)';
      var sheet = null;
      var applied = new Set();
      var seenClasses = new Set();
      var seenIds = new Set();
      var exceptions = [];
      var allowGeneric = true;

      function styleSheet() {
        if (sheet) { return sheet; }
        var element = document.createElement('style');
        element.setAttribute('data-blocker', '');
        (document.head || document.documentElement).appendChild(element);
        sheet = element.sheet;
        return sheet;
      }

      function hide(selectors) {
        if (!selectors || !selectors.length) { return; }
        var fresh = [];
        for (var i = 0; i < selectors.length; i++) {
          if (!applied.has(selectors[i])) {
            applied.add(selectors[i]);
            fresh.push(selectors[i]);
          }
        }
        if (!fresh.length) { return; }
        var target = styleSheet();
        if (!target) { return; }
        // Batched, but small enough that one bad selector costs a handful of
        // rules rather than all of them.
        for (var start = 0; start < fresh.length; start += 25) {
          var batch = fresh.slice(start, start + 25);
          try {
            target.insertRule(batch.join(',') + '{display:none !important;}',
                              target.cssRules.length);
          } catch (e) {
            // Retry the batch one at a time to salvage the valid ones.
            for (var j = 0; j < batch.length; j++) {
              try {
                target.insertRule(batch[j] + '{display:none !important;}',
                                  target.cssRules.length);
              } catch (e2) {}
            }
          }
        }
      }

      /// Collect class names and ids not reported yet.
      function newTokens() {
        var classes = [];
        var ids = [];
        var nodes = document.querySelectorAll('[class],[id]');
        for (var i = 0; i < nodes.length; i++) {
          var node = nodes[i];
          var list = node.classList;
          if (list) {
            for (var j = 0; j < list.length; j++) {
              if (!seenClasses.has(list[j])) {
                seenClasses.add(list[j]);
                classes.push(list[j]);
              }
            }
          }
          var id = node.id;
          if (id && !seenIds.has(id)) {
            seenIds.add(id);
            ids.push(id);
          }
        }
        return { classes: classes, ids: ids };
      }

      function askGeneric() {
        if (!allowGeneric) { return; }
        var tokens = newTokens();
        if (!tokens.classes.length && !tokens.ids.length) { return; }
        bridge.postMessage({
          token: TOKEN, kind: 'generic',
          classes: tokens.classes, ids: tokens.ids, exceptions: exceptions
        }).then(hide, function() {});
      }

      function askForPage(url) {
        bridge.postMessage({ token: TOKEN, kind: 'page', url: url })
          .then(function(result) {
            if (!result) { return; }
            exceptions = result.exceptions || [];
            allowGeneric = result.generichide !== true;
            hide(result.hide);
            askGeneric();
          }, function() {});
      }

      askForPage(location.href);

      // A single-page app changes route without loading a document, so nothing
      // above would ever run again — the rules for the new URL would never be
      // asked for. The native side sees those navigations (it already watches
      // them for history) and calls this. Selectors are cumulative and
      // deduplicated, so re-running only ever adds what the new route needs.
      window.__mbCosmeticRefresh = function(url) {
        askForPage(url || location.href);
      };

      // Single-page apps swap in new markup constantly, so new classes and ids
      // keep appearing. Batched through rAF — an unthrottled observer on a busy
      // page is a measurable frame cost.
      var scheduled = false;
      new MutationObserver(function() {
        if (scheduled) { return; }
        scheduled = true;
        requestAnimationFrame(function() {
          scheduled = false;
          askGeneric();
        });
      }).observe(document.documentElement,
                 { childList: true, subtree: true, attributes: true,
                   attributeFilter: ['class', 'id'] });
    })();
    """

    /// Keeps video soundtracks playing after the app is backgrounded. Only
    /// injected when `Settings.backgroundPlayback` is on, which is off by
    /// default.
    ///
    /// `UIBackgroundModes: audio` plus an active `.playback` audio session is
    /// enough for the *system* to let audio continue. It isn't enough for video
    /// sites, which watch the Page Visibility API and pause themselves the
    /// moment the page is hidden. Three changes are needed to stop that:
    ///
    /// 1. `document.visibilityState` and `document.hidden` are patched on
    ///    `Document.prototype` to always report the page as visible. Both, and
    ///    consistently — a site that checks `hidden` would otherwise see a
    ///    contradiction and pause anyway.
    /// 2. `HTMLVideoElement.play`/`pause` are wrapped to record whether the
    ///    *user* asked for the pause. A pause nobody asked for, while the page is
    ///    really hidden, is undone by calling the original `play`.
    /// 3. `webkitpresentationmodechanged` is stopped from propagating, so
    ///    leaving fullscreen on backgrounding doesn't trigger the site's own
    ///    teardown.
    ///
    /// This is the same technique other iOS browsers ship (
    /// behind their "Enable Background Audio" setting) and for the same reason:
    /// there is no Apple API that makes a web page stop noticing it was hidden.
    /// The originals are captured up front and always called through, so the
    /// page's own behaviour is unchanged apart from the visibility answer.
    private static let mediaBackgrounding = """
    (function() {
      var descriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'visibilityState');
      var hiddenDescriptor = Object.getOwnPropertyDescriptor(Document.prototype, 'hidden');
      if (!descriptor || !descriptor.get) { return; }
      var realVisibility = descriptor.get;

      Object.defineProperty(Document.prototype, 'visibilityState', {
        enumerable: descriptor.enumerable,
        configurable: descriptor.configurable,
        get: function() {
          var value = realVisibility.call(this);
          return value !== 'visible' ? 'visible' : value;
        }
      });

      if (hiddenDescriptor && hiddenDescriptor.get) {
        Object.defineProperty(Document.prototype, 'hidden', {
          enumerable: hiddenDescriptor.enumerable,
          configurable: hiddenDescriptor.configurable,
          get: function() { return false; }
        });
      }

      var realPlay = HTMLVideoElement.prototype.play;
      var realPause = HTMLVideoElement.prototype.pause;

      HTMLVideoElement.prototype.play = function() {
        this.__userPaused = false;
        return realPlay.apply(this, arguments);
      };
      HTMLVideoElement.prototype.pause = function() {
        // Reached only when something called pause() explicitly, which is as
        // close to "the user meant it" as the page will tell us.
        this.__userPaused = true;
        return realPause.apply(this, arguments);
      };

      function watch(element) {
        if (element.__backgroundingWatched) { return; }
        element.__backgroundingWatched = true;

        element.addEventListener('pause', function() {
          // Only resume a pause the page imposed on itself while genuinely
          // hidden. `realVisibility` is the unpatched getter, so this sees the
          // truth the page no longer can.
          if (element.__userPaused || element.ended) { return; }
          if (realVisibility.call(document) === 'visible') { return; }
          realPlay.call(element);
        }, false);

        // Backgrounding kicks video out of fullscreen; letting that reach the
        // page's handler is what tears playback down on some sites.
        element.addEventListener('webkitpresentationmodechanged', function(e) {
          e.stopPropagation();
        }, true);
      }

      document.querySelectorAll('video').forEach(watch);

      // Players are usually created after this script runs, so new ones have to
      // be picked up as they appear. Batched through rAF: an unthrottled
      // observer on a busy page is a measurable frame cost.
      var pending = [];
      var scheduled = false;
      new MutationObserver(function(mutations) {
        pending.push.apply(pending, mutations);
        if (scheduled) { return; }
        scheduled = true;
        requestAnimationFrame(function() {
          scheduled = false;
          var batch = pending;
          pending = [];
          batch.forEach(function(mutation) {
            mutation.addedNodes.forEach(function(node) {
              if (node instanceof HTMLVideoElement) {
                watch(node);
              } else if (node.querySelectorAll) {
                node.querySelectorAll('video').forEach(watch);
              }
            });
          });
        });
      }).observe(document, { childList: true, subtree: true });
    })();
    """

    /// Hide the strip a video site pins over the player while you scroll: its
    /// logo, a search button, an overflow menu and a prompt to open its app.
    ///
    /// A display preference, not blocking. Nothing here is an ad, and nothing
    /// the page needs to work goes away — the chrome is hidden and its space
    /// given back to the video.
    ///
    /// Written as a stylesheet rather than as filter rules on purpose. Filter
    /// rules are all-or-nothing with the list they live in, and this is a
    /// per-user preference that should hold whatever the blocking level is,
    /// including off. It runs in an isolated world: it only adds a stylesheet,
    /// so the page has no reason to see it.
    ///
    /// The selectors cover both the mobile and desktop hosts. Anything that
    /// doesn't match costs nothing, which matters because a site can rename its
    /// internals any week it likes — a stale selector degrades to doing
    /// nothing rather than to hiding the wrong thing.
    private static let hideVideoTopBar = """
    (function() {
      var hosts = ['youtube.com', 'youtu.be'];
      var host = location.hostname.replace(/^www\\.|^m\\./, '');
      var matched = false;
      for (var i = 0; i < hosts.length; i++) {
        if (host === hosts[i] || host.endsWith('.' + hosts[i])) { matched = true; }
      }
      if (!matched) { return; }
      if (document.getElementById('mb-hide-topbar')) { return; }

      var style = document.createElement('style');
      style.id = 'mb-hide-topbar';
      // Three rules, because the bar is three things.
      //
      // The bar itself is `position: fixed`, so hiding it frees no space —
      // which is why hiding it alone leaves a black band and nothing moves up.
      // The space is reserved separately: the app pads its own top by the bar's
      // height while the player is pinned, and the player is positioned at that
      // same offset. All three have to go, or the band stays and the player
      // sits over the text below it.
      style.textContent = [
        'ytm-header, ytm-mobile-topbar-renderer { display: none !important; }',
        'ytm-app.sticky-player, ytm-app.is-automotive { padding-top: 0 !important; }',
        '.player-container, .player-container.sticky-player { top: 0 !important; }',
        // Desktop layout, for the same page in a wide window.
        '#masthead-container, ytd-masthead { display: none !important; }',
        'ytd-app { --ytd-masthead-height: 0px !important; }'
      ].join('\\n');
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    /// Ask the player for the best quality the video has.
    ///
    /// The player exposes the same controls its own quality menu uses, and the
    /// list it returns is ordered best-first. So this is not a trick or an
    /// override — it is the menu choice you would have made, made for you on
    /// every video.
    ///
    /// It has to be reapplied rather than set once. The site is a single-page
    /// app: the player object survives from video to video, and each new one
    /// arrives with the quality the site picked for the connection. So the work
    /// happens on every `loadedmetadata`, plus a short bounded retry after
    /// each, because the quality list is empty for the first moments of a load
    /// and setting a range against an empty list does nothing.
    private static let highestQualityPlayback = """
    (function() {
      var host = location.hostname.replace(/^www\\.|^m\\./, '');
      if (host !== 'youtube.com' && !host.endsWith('.youtube.com')) { return; }
      if (window.__mbHighestQuality) { return; }
      window.__mbHighestQuality = true;

      function apply() {
        var player = document.getElementById('movie_player')
                  || document.querySelector('.html5-video-player');
        if (!player || typeof player.getAvailableQualityLevels !== 'function') {
          return false;
        }
        var levels;
        try { levels = player.getAvailableQualityLevels(); } catch (e) { return false; }
        // Empty until the player has the video's formats; that's the retry case.
        if (!levels || !levels.length) { return false; }
        var best = levels[0];
        try {
          // The range is what sticks: `setPlaybackQuality` alone gets revised
          // back down the moment the player next re-evaluates the connection.
          if (typeof player.setPlaybackQualityRange === 'function') {
            player.setPlaybackQualityRange(best, best);
          }
          if (typeof player.setPlaybackQuality === 'function') {
            player.setPlaybackQuality(best);
          }
        } catch (e) { return false; }
        return true;
      }

      // Bounded: a handful of attempts over a few seconds, then stop. An
      // unbounded timer on a page you left open all day is a battery cost for
      // nothing.
      function applyWithRetries() {
        var attempts = 0;
        (function attempt() {
          if (apply() || attempts >= 12) { return; }
          attempts += 1;
          setTimeout(attempt, 500);
        })();
      }

      document.addEventListener('loadedmetadata', function (e) {
        var tag = e.target && e.target.tagName;
        if (tag && tag.toLowerCase() === 'video') { applyWithRetries(); }
      }, true);

      applyWithRetries();
    })();
    """

    /// Fingerprinting defence: perturbing the readings rather than blocking the
    /// APIs — the technique usually called *farbling*.
    ///
    /// A fingerprinting script doesn't ask who you are; it reads a few dozen
    /// APIs whose answers differ slightly per device and hashes them together.
    /// Any single answer is unremarkable; the combination is close to unique
    /// and, crucially, *stable*, which is what makes it worth collecting. So the
    /// readings are perturbed by an amount derived from a per-origin,
    /// per-session key: plausible, and consistent within a page, while the
    /// cross-site and cross-launch stability a tracker needs is gone.
    ///
    /// **Canvas and WebGL are deliberately left alone**, and that is the whole
    /// lesson of this file. Farbling a canvas from JavaScript means replacing
    /// `getImageData`, `toDataURL` and `toBlob`, and a bot check reads a canvas
    /// precisely because doing so catches browsers that have. Cloudflare's
    /// "verify you are human" failed for exactly that reason. Brave farbles
    /// canvas on desktop — but it does it inside Blink, where there is no
    /// replaced function to find. In a `WKWebView` there is no equivalent seam,
    /// and Brave's own iOS browser therefore farbles no canvas at all. What it
    /// does farble is the four things below, and this is a port of that set:
    /// audio, plugins, speech voices, and core count.
    ///
    /// The trade is worth making in both directions. Canvas farbling bought
    /// little on iOS — every iPhone of a given model rasterises identically, so
    /// the reading is far less identifying here than on desktop — and it cost
    /// access to any site behind a challenge.
    ///
    /// Each part is wrapped so a failure leaves the original behaviour in place.
    /// A page broken by this is worse than a page that fingerprints.
    private static let fingerprintProtection = """
    (function() {
      if (window.__mbFarbled) { return; }
      window.__mbFarbled = true;

      \(challengeSurfaceTest)
      if (onChallengeSurface()) { return; }

      var mask = window.__mbMask || function(wrapper) { return wrapper; };

      // Session key: constant for this launch, different next launch. Combined
      // with the origin so two sites can't compare notes on what they measured.
      var KEY = '\(securityToken)';

      function hash(text) {
        var h = 2166136261;
        for (var i = 0; i < text.length; i++) {
          h ^= text.charCodeAt(i);
          h = (h * 16777619) >>> 0;
        }
        return h >>> 0;
      }

      // xorshift32, drawn from in a fixed order, so every reading this session
      // makes on this origin agrees with the last one.
      var state = hash(KEY + '|' + (location.origin || 'null')) || 1;
      function random() {
        state ^= state << 13; state >>>= 0;
        state ^= state >> 17;
        state ^= state << 5;  state >>>= 0;
        return state / 4294967296;
      }

      // MARK: 1 — Audio
      //
      // The analyser's readings differ slightly by device. Scaling them by a
      // factor just under 1 leaves the numbers inside their documented range
      // and far below anything audible, while moving them enough to break a
      // hash. `AudioBuffer.getChannelData` is left alone: it hands back the
      // page's own decoded samples, and quietly altering those is a change to
      // the audio itself rather than to a measurement of it.
      try {
        var fudge = 0.99 + random() * 0.01;

        [[window.AnalyserNode, 'getFloatFrequencyData'],
         [window.AnalyserNode, 'getByteFrequencyData'],
         [window.AnalyserNode, 'getByteTimeDomainData'],
         [window.AnalyserNode, 'getFloatTimeDomainData']].forEach(function(pair) {
          var type = pair[0], name = pair[1];
          if (!type || !type.prototype || !type.prototype[name]) { return; }
          var original = type.prototype[name];
          type.prototype[name] = mask(function() {
            var result = original.apply(this, arguments);
            var destination = arguments[0];
            if (destination && destination.length) {
              for (var i = 0; i < destination.length; i++) {
                destination[i] = destination[i] * fudge;
              }
            }
            return result;
          }, original);
        });
      } catch (e) {}

      // MARK: 2 — Plugins
      //
      // Safari reports a fixed list of five PDF entries, identical on every
      // iPhone, so there is nothing to perturb — but a list that is *appended*
      // to differs per origin without any entry of it being false about the
      // device. Built on the real `Plugin` and `MimeType` prototypes, because a
      // plain object in their place is a far louder signal than the plugin
      // count ever was.
      try {
        var plugins = window.navigator.plugins;
        if (plugins && window.Plugin && window.MimeType && plugins.length > 0) {
          var names = ['Portable Document Format', 'Document Viewer', 'PDF Reader'];
          var fakeName = names[Math.floor(random() * names.length)] +
                         ' ' + (2 + Math.floor(random() * 8));

          var mime = Object.create(window.MimeType.prototype, {
            suffixes:    { value: 'pdf' },
            type:        { value: 'application/pdf' },
            description: { value: '' }
          });
          var plugin = Object.create(window.Plugin.prototype, {
            description: { value: '' },
            name:        { value: fakeName },
            filename:    { value: 'internal-pdf-viewer' },
            length:      { value: 1 }
          });
          plugin[0] = mime;
          plugin['application/pdf'] = mime;
          Reflect.defineProperty(mime, 'enabledPlugin', { value: plugin });
          plugin.item = function(index) { return plugin[index]; };

          var prototype = Object.getPrototypeOf(plugins);
          var realLength = plugins.length;

          prototype[realLength] = plugin;
          prototype[fakeName] = plugin;

          var realItem = plugins.item;
          prototype.item = mask(function(index) {
            return index < realLength ? realItem.apply(this, arguments) : plugin;
          }, realItem);

          var realNamedItem = plugins.namedItem;
          prototype.namedItem = mask(function(name) {
            return realNamedItem.apply(this, arguments)
                || (name === fakeName ? plugin : null);
          }, realNamedItem);

          Reflect.defineProperty(prototype, 'length', { value: realLength + 1 });
        }
      } catch (e) {}

      // MARK: 3 — Speech voices
      //
      // The installed voice list is stable per device and long enough to
      // identify one. An extra voice is appended, and any attempt to *speak*
      // with it is redirected to the real voice it was modelled on — a fake
      // voice cannot actually produce sound, and a site that picked it would
      // otherwise fall silent.
      try {
        if (window.speechSynthesis && window.SpeechSynthesisUtterance) {
          var voiceScale = random();
          var fakeVoice, realVoice, requestedFake;

          var voiceProperty = Reflect.getOwnPropertyDescriptor(
            SpeechSynthesisUtterance.prototype, 'voice');
          if (voiceProperty && voiceProperty.get && voiceProperty.set) {
            Reflect.defineProperty(SpeechSynthesisUtterance.prototype, 'voice', {
              configurable: voiceProperty.configurable,
              enumerable: voiceProperty.enumerable,
              get: function() {
                return requestedFake || voiceProperty.get.apply(this, arguments);
              },
              set: function(value) {
                if (value === fakeVoice && realVoice !== undefined) {
                  requestedFake = value;
                  voiceProperty.set.apply(this, [realVoice]);
                } else {
                  requestedFake = undefined;
                  voiceProperty.set.apply(this, arguments);
                }
              }
            });
          }

          var synthesis = Object.getPrototypeOf(window.speechSynthesis);
          var realGetVoices = synthesis.getVoices;
          synthesis.getVoices = mask(function() {
            var voices = realGetVoices.apply(this, arguments);
            if (!voices || !voices.length) { return voices; }
            if (fakeVoice === undefined) {
              realVoice = voices[Math.min(voices.length - 1,
                                          Math.round(voiceScale * voices.length))];
              if (!realVoice) { return voices; }
              fakeVoice = Object.create(Object.getPrototypeOf(realVoice), {
                name:         { value: realVoice.name + ' (Enhanced)' },
                voiceURI:     { value: realVoice.voiceURI },
                lang:         { value: realVoice.lang },
                localService: { value: realVoice.localService },
                default:      { value: false }
              });
            }
            voices.push(fakeVoice);
            return voices;
          }, realGetVoices);
        }
      } catch (e) {}

      // MARK: 4 — Core count
      //
      // Reported as a value between 2 and the real count, never above it and
      // never below 2 — a phone claiming one core or thirty-two is more
      // distinctive than one telling the truth. Machines with two or fewer are
      // left alone, there being no room to move.
      try {
        var coreScale = random();
        var cores = window.navigator.hardwareConcurrency;
        if (cores > 2) {
          Reflect.defineProperty(window.navigator, 'hardwareConcurrency', {
            configurable: true,
            value: 2 + Math.round((cores - 2) * coreScale)
          });
        }
      } catch (e) {}
    })();
    """
}
