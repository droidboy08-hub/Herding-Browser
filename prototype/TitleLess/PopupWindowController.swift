import UIKit
import WebKit

/// A real second window, for the pop-ups that have to be real.
///
/// Everything else in this browser is one web view, and pop-ups were refused by
/// returning `nil` from `createWebViewWith` — which suppresses ad windows
/// perfectly and breaks every sign-in flow ever written.
///
/// A "Continue with Google" button calls `window.open`, and then depends on
/// three things that only exist if a window was actually created:
///
/// * `window.open` returns a **handle**, not `null`. A page that gets `null`
///   assumes pop-ups are blocked and, in most implementations, stops.
/// * The new window has an **opener**. The provider posts the result back
///   through `window.opener.postMessage`, and with no opener there is nobody to
///   post to — which is why the account picker completes and then nothing
///   happens.
/// * The window can **close itself**. The last thing the callback page does is
///   `window.close()`.
///
/// None of that can be faked by loading the URL somewhere else, which is why
/// opening it as a tab still produced a blank page. WebKit sets up the opener
/// relationship only when this delegate hands back a web view built with the
/// configuration it was given — so that is what this does.
final class PopupWindowController: UIViewController {

    let webView: WKWebView
    /// A download started in here. The browser dismisses the window and says so.
    var onDownloadStarted: (() -> Void)?
    private let bar = UIView()
    private let originLabel = UILabel()
    private var titleObservation: NSKeyValueObservation?

    /// - Parameter configuration: WebKit's, not ours. Passing a different one
    ///   is what silently breaks the opener relationship.
    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        // Who you are talking to, and a way out. A sign-in window that can't be
        // read or dismissed is a phishing surface, so the origin is always
        // shown and the sheet is always dismissible.
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.backgroundColor = .secondarySystemBackground
        view.addSubview(bar)

        originLabel.translatesAutoresizingMaskIntoConstraints = false
        originLabel.font = .systemFont(ofSize: 13, weight: .medium)
        originLabel.textColor = .secondaryLabel
        originLabel.textAlignment = .center
        originLabel.lineBreakMode = .byTruncatingMiddle
        bar.addSubview(originLabel)

        let done = UIButton(type: .system)
        done.translatesAutoresizingMaskIntoConstraints = false
        done.setTitle("Done", for: .normal)
        done.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .primaryActionTriggered)
        bar.addSubview(done)

        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            originLabel.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            originLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            originLabel.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: 16),

            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            done.leadingAnchor.constraint(greaterThanOrEqualTo: originLabel.trailingAnchor, constant: 8),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // The URL is set by WebKit after this returns — it loads the request
        // itself once the delegate hands the view back — so the label follows
        // it rather than being set once.
        titleObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
            Task { @MainActor in self?.originLabel.text = view.url?.host }
        }

        // Its own navigation delegate, and deliberately not the browser's.
        //
        // This window had none at all, which is why a download started in here
        // went nowhere: every download hook in this app is a
        // `WKNavigationDelegate` method, so a page could announce that a file
        // was on its way and WebKit would then have nobody to hand it to.
        //
        // Not the browser's, though. That delegate is written throughout as if
        // its web view were *the* web view — it drives the address capsule, the
        // history record, the tab's session state. Pointing it at a second web
        // view would have this window quietly rewriting the state of the page
        // behind it. So this handles the two things a pop-up genuinely needs
        // and nothing else.
        webView.navigationDelegate = self
    }
}

// MARK: - Downloads

extension PopupWindowController: WKNavigationDelegate {

    /// The same test the browser makes: anything WebKit cannot display, or
    /// anything the server marks as an attachment, is a download.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        let isAttachment = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?
            .lowercased().contains("attachment") ?? false

        decisionHandler(!navigationResponse.canShowMIMEType || isAttachment ? .download : .allow)
    }

    func webView(_ webView: WKWebView,
                 navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(
            download, suggestedName: navigationResponse.response.suggestedFilename)
        onDownloadStarted?()
    }

    /// A link carrying the `download` attribute starts life as a navigation.
    func webView(_ webView: WKWebView,
                 navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        DownloadManager.shared.adopt(download)
        onDownloadStarted?()
    }
}
