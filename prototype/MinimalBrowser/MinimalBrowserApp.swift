import SwiftUI

@main
struct MinimalBrowserApp: App {
    /// One profile owns all storage for the session. Swapping this for
    /// `BrowserProfile(isPrivate: true)` gives a fully private browser — in-memory
    /// database, no session file, non-persistent website data — with no other
    /// change anywhere in the app.
    private let profile: Profile = BrowserProfile()

    var body: some Scene {
        WindowGroup {
            BrowserContainer(profile: profile)
                .ignoresSafeArea()
                .statusBarHidden(false)
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
