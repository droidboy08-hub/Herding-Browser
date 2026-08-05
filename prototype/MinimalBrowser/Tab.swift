import UIKit

/// A single open page. Tabs live as a scrollable list in the start box rather
/// than a tab strip. The browser reuses one web view and loads the selected
/// tab's URL, so a tab is its identity, its last-known title/URL, the site's
/// favicon, and the WebKit session state needed to restore its back/forward list.
struct Tab: Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var icon: UIImage? = nil
    /// Page snapshot shown on the grid cards (captured when leaving the page).
    var snapshot: UIImage? = nil
    /// `WKWebView.interactionState` — the tab's whole back/forward list plus
    /// scroll position, opaque to us. Captured when switching away, so coming
    /// back restores the session rather than reloading a bare URL.
    var sessionState: Data? = nil
    var lastUsed: Date = Date()
}
