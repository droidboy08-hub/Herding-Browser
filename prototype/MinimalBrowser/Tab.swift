import UIKit

/// A single open page. Tabs live as a scrollable list in the start box rather
/// than a tab strip. The browser reuses one web view and loads the selected
/// tab's URL, so a tab is just its identity + last-known title/URL + the site's
/// favicon.
struct Tab: Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var icon: UIImage? = nil
}
