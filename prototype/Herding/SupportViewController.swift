import UIKit

/// What a support row is asking for.
enum SupportDestination {
    case help
    case feedback
    /// Feedback about the page you are on, which is most of what a browser
    /// gets told about — the address goes in the draft so the report is
    /// actionable without a second exchange.
    case siteProblem
}

/// Where to fill in who you are and how someone reaches you.
///
/// Everything here is deliberately blank. Two of these are not optional if the
/// app is going to the App Store: the listing requires a support URL and a
/// privacy policy URL, and review rejects a submission without them. The rest
/// is what a browser is expected to have — somewhere to report a site that
/// renders wrongly, and a name attached to the thing.
///
/// Filling any one of these in makes its row appear. Leaving one blank leaves
/// it out entirely rather than shipping a row that opens nothing.
enum SupportInfo {

    /// Shown as the developer, in About and in the legal documents.
    /// e.g. "Jane Smith" or "Acme Software Ltd".
    static let developerName = ""

    /// Where someone goes for help. Required by App Store Connect.
    /// e.g. "https://example.com/support"
    static let supportURL = "https://droidboy08-hub.github.io/herding-site/support.html"

    /// Where feedback and bug reports go. An address is fine — the app opens a
    /// pre-addressed mail with the version filled in.
    /// e.g. "help@example.com"
    static let contactEmail = "herdingbrowser@gmail.com"

    /// The privacy policy, hosted. The app also carries the policy offline, but
    /// App Store Connect wants a URL and will not accept the in-app copy.
    /// e.g. "https://example.com/privacy"
    static let privacyPolicyURL = "https://droidboy08-hub.github.io/herding-site/privacy.html"

    static var hasSupportURL: Bool { !supportURL.isEmpty }
    static var hasContact: Bool { !contactEmail.isEmpty }

    /// A mail draft with the things you would otherwise have to ask for.
    ///
    /// The version and the device are in the subject because the first reply to
    /// any bug report is otherwise a request for them. Nothing about browsing
    /// is included, and nothing is sent — this opens the mail app with a draft
    /// the person can read and delete.
    static func feedbackURL(subject: String) -> URL? {
        guard hasContact else { return nil }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let system = "iOS \(UIDevice.current.systemVersion)"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = contactEmail
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "\(subject) — version \(version) (\(build)), \(system)")
        ]
        return comps.url
    }
}
