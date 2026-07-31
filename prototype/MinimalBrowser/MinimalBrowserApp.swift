import SwiftUI

@main
struct MinimalBrowserApp: App {
    var body: some Scene {
        WindowGroup {
            BrowserContainer()
                .ignoresSafeArea()
                .statusBarHidden(false)
        }
    }
}

struct BrowserContainer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BrowserViewController {
        BrowserViewController()
    }
    func updateUIViewController(_ uiViewController: BrowserViewController, context: Context) {}
}
