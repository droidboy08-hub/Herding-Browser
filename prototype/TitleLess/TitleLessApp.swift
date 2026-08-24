import SwiftUI

/// Whether the status bar is showing, in the one place SwiftUI will listen to.
///
/// The status bar belongs to the hosting controller, not to the view controller
/// inside it. `BrowserViewController` overriding `prefersStatusBarHidden` did
/// nothing at all — SwiftUI never asks a representable, and the `WindowGroup`
/// below was pinning the answer to `false` besides. So the browser publishes
/// what it wants here and SwiftUI reads it.
///
/// A singleton because the view controller is built inside `makeUIViewController`,
/// where there is nothing to inject into.
@MainActor
final class StatusBarState: ObservableObject {
    static let shared = StatusBarState()
    @Published var hidden = false
    private init() {}
}

@main
struct TitleLessApp: App {
    /// One profile owns all storage for the session. Swapping this for
    /// `BrowserProfile(isPrivate: true)` gives a fully private browser — in-memory
    /// database, no session file, non-persistent website data — with no other
    /// change anywhere in the app.
    private let profile: Profile = BrowserProfile()

    @StateObject private var statusBar = StatusBarState.shared

    var body: some Scene {
        WindowGroup {
            BrowserContainer(profile: profile)
                .ignoresSafeArea()
                .statusBarHidden(statusBar.hidden)
        }
    }
}

struct BrowserContainer: UIViewControllerRepresentable {
    let profile: Profile

    func makeUIViewController(context: Context) -> BrowserViewController {
        BrowserViewController(profile: profile)
    }
    func updateUIViewController(_ uiViewController: BrowserViewController, context: Context) {}
}
