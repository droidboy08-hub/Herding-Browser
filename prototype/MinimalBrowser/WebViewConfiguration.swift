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

      function report(value) {
        try { bridge.postMessage({ scrollable: value }); } catch (e) {}
      }

      document.addEventListener('touchstart', function(event) {
        var touch = event.target;
        report(!!touch && scrollableAncestor(touch));
      }, { capture: true, passive: true });

      // Cleared on release, so a stale "yes" from the last touch can't block
      // the next gesture.
      document.addEventListener('touchend', function() { report(false); },
                                { capture: true, passive: true });
      document.addEventListener('touchcancel', function() { report(false); },
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

      // A request this level would never block: don't ask, don't wrap it in a
      // promise, don't delay it by a single turn of the event loop.
      function skip(url) {
        if (BLOCKS_FIRST_PARTY) { return false; }
        try { return registrable(new URL(url).hostname) === PAGE_DOMAIN; }
        catch (e) { return false; }
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
        window.fetch = function() {
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
        };
      }

      var realOpen = XMLHttpRequest.prototype.open;
      var realSend = XMLHttpRequest.prototype.send;

      XMLHttpRequest.prototype.open = function(method, url, async) {
        // A synchronous request can't wait on a promise, so it is left alone.
        this.__blockCheckURL = (async === undefined || async) ? absolute(url) : null;
        return realOpen.apply(this, arguments);
      };

      XMLHttpRequest.prototype.send = function() {
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
      };
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
    /// APIs whose answers differ slightly per device — how a canvas renders text,
    /// what the audio pipeline does to a waveform, how many cores you have — and
    /// hashes them together. Any single answer is unremarkable; the combination
    /// is close to unique and, crucially, *stable*, which is what makes it
    /// worth collecting.
    ///
    /// Returning constants would be worse than useless: everyone reporting the
    /// same fake value makes this browser itself the fingerprint. So the readings
    /// are perturbed instead, by an amount derived from a per-origin,
    /// per-session key. The values stay plausible and stay consistent within a
    /// page — a site comparing two canvas reads in the same session sees them
    /// agree — while the *cross-site* and cross-launch stability the tracker
    /// needs is gone.
    ///
    /// Everything is wrapped so a failure leaves the original behaviour in
    /// place. A page that breaks because of this is worse than a page that
    /// fingerprints.
    private static let fingerprintProtection = """
    (function() {
      if (window.__mbFarbled) { return; }
      window.__mbFarbled = true;

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

      var seed = hash(KEY + '|' + (location.origin || 'null'));

      // xorshift32: deterministic from the seed, so repeated reads of the same
      // API in one session agree with each other.
      function makeRandom(state) {
        var s = state || 1;
        return function() {
          s ^= s << 13; s >>>= 0;
          s ^= s >> 17;
          s ^= s << 5;  s >>>= 0;
          return s / 4294967296;
        };
      }

      function define(object, name, value) {
        try {
          Object.defineProperty(object, name, {
            get: function() { return value; },
            configurable: true
          });
        } catch (e) {}
      }

      // MARK: Canvas
      // The classic fingerprint: draw text and read the pixels back. Rendering
      // differs by GPU, driver and font stack, so the bytes are near-unique.
      // Flipping the low bit of a scattered handful of pixels is invisible to a
      // human and fatal to a hash.
      function perturb(data) {
        var random = makeRandom(seed);
        var step = 977;                      // prime, so the pattern doesn't line
        for (var i = 0; i < data.length; i += step) {
          var delta = random() < 0.5 ? 1 : -1;
          var v = data[i] + delta;
          data[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
        }
      }

      try {
        var realGetImageData = CanvasRenderingContext2D.prototype.getImageData;
        CanvasRenderingContext2D.prototype.getImageData = function() {
          var result = realGetImageData.apply(this, arguments);
          try { perturb(result.data); } catch (e) {}
          return result;
        };
      } catch (e) {}

      try {
        // `toDataURL` and `toBlob` read the same pixels without going through
        // `getImageData`, so they need the noise applied on their own path.
        function farbleCanvas(canvas) {
          var copy = document.createElement('canvas');
          copy.width = canvas.width;
          copy.height = canvas.height;
          var context = copy.getContext('2d');
          context.drawImage(canvas, 0, 0);
          var image = realGetImageData.call(context, 0, 0, copy.width, copy.height);
          perturb(image.data);
          context.putImageData(image, 0, 0);
          return copy;
        }

        var realToDataURL = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function() {
          try {
            return realToDataURL.apply(farbleCanvas(this), arguments);
          } catch (e) {
            return realToDataURL.apply(this, arguments);
          }
        };

        var realToBlob = HTMLCanvasElement.prototype.toBlob;
        HTMLCanvasElement.prototype.toBlob = function() {
          try {
            return realToBlob.apply(farbleCanvas(this), arguments);
          } catch (e) {
            return realToBlob.apply(this, arguments);
          }
        };
      } catch (e) {}

      // MARK: WebGL
      // `UNMASKED_VENDOR_WEBGL` / `UNMASKED_RENDERER_WEBGL` name the exact GPU.
      // Nothing on the page needs that; report what a generic Apple device does.
      try {
        [window.WebGLRenderingContext, window.WebGL2RenderingContext].forEach(function(type) {
          if (!type) { return; }
          var realGetParameter = type.prototype.getParameter;
          type.prototype.getParameter = function(parameter) {
            if (parameter === 37445) { return 'Apple Inc.'; }
            if (parameter === 37446) { return 'Apple GPU'; }
            return realGetParameter.apply(this, arguments);
          };
        });
      } catch (e) {}

      // MARK: Audio
      // The Web Audio pipeline produces subtly different floats per device. The
      // noise is far below anything audible and far above hash stability.
      try {
        var realGetChannelData = AudioBuffer.prototype.getChannelData;
        AudioBuffer.prototype.getChannelData = function() {
          var data = realGetChannelData.apply(this, arguments);
          try {
            var random = makeRandom(seed + 1);
            for (var i = 0; i < data.length; i += 449) {
              data[i] = data[i] + (random() - 0.5) * 1e-7;
            }
          } catch (e) {}
          return data;
        };

        var realFrequency = AnalyserNode.prototype.getFloatFrequencyData;
        AnalyserNode.prototype.getFloatFrequencyData = function(array) {
          realFrequency.apply(this, arguments);
          try {
            var random = makeRandom(seed + 2);
            for (var i = 0; i < array.length; i += 43) {
              array[i] = array[i] + (random() - 0.5) * 1e-4;
            }
          } catch (e) {}
        };
      } catch (e) {}

      // MARK: Device and locale
      // Small integers that vary by model, and a plugin list that on iOS says
      // nothing true anyway. Reported as the most common answer rather than a
      // random one — blending in beats standing out.
      define(navigator, 'hardwareConcurrency', 4);
      define(navigator, 'deviceMemory', 8);
      define(navigator, 'plugins', []);
      define(navigator, 'mimeTypes', []);
      define(navigator, 'languages', ['en-US', 'en']);
      // WebKit's own battery/connection surfaces, where present, are pure signal.
      define(navigator, 'connection', undefined);
      define(navigator, 'getBattery', undefined);
    })();
    """
}
