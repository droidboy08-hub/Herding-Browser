import UIKit

/// The documents an app is expected to have before it ships.
enum LegalDocument {
    case privacy
    case terms

    /// For the navigation bar, where the app's name is not in question.
    var title: String {
        switch self {
        case .privacy: return "Privacy Policy"
        case .terms:   return "Terms of Use"
        }
    }

    /// For the top of the document itself, where it is.
    ///
    /// A policy is read outside the app as often as inside it — screenshotted,
    /// pasted into a review form, sent to somebody — and a page headed only
    /// "Privacy Policy" does not say whose.
    var heading: String {
        switch self {
        case .privacy: return "TitleLess Browser Privacy Policy"
        case .terms:   return "TitleLess Browser Terms of Use"
        }
    }
}

/// Privacy Policy and Terms of Use, carried in the app rather than linked.
///
/// Bundled deliberately. A policy behind a URL is a policy that can go missing,
/// change without the version of the app it applied to, or fail to load on the
/// one connection the reader has — and a privacy policy that has to be fetched
/// is itself a network request made on the reader's behalf. This is the version
/// that shipped with this build, readable offline, and it changes only when the
/// app does.
///
/// The text describes what the code in this repository actually does. Anything
/// added later that touches the network or storage has to be added here in the
/// same change.
final class LegalViewController: UIViewController {

    private let document: LegalDocument
    private let textView = UITextView()

    init(document: LegalDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = document.title
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 18, bottom: 32, right: 18)
        textView.attributedText = Self.render(document == .privacy ? Self.privacy : Self.terms,
                                              titled: document.heading)
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    /// Lines starting with `#` are headings; everything else is body text.
    private static func render(_ source: String, titled heading: String) -> NSAttributedString {
        let output = NSMutableAttributedString()

        // The document's own title, a step above the section headings so the
        // two do not read as the same rank.
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 10
        output.append(NSAttributedString(
            string: heading + "\n",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .title1).bold,
                         .foregroundColor: UIColor.label,
                         .paragraphStyle: titleParagraph]))

        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("# ") {
                output.append(NSAttributedString(
                    string: line.dropFirst(2) + "\n",
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .headline),
                                 .foregroundColor: UIColor.label]))
            } else {
                output.append(NSAttributedString(
                    string: line + "\n",
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .callout),
                                 .foregroundColor: UIColor.secondaryLabel]))
            }
        }
        return output
    }

    // MARK: - The documents

    private static let privacy = """
    TitleLess has no account, no sign-in, and no analytics. Nothing you do in it \
    is sent to its developer, because there is nowhere for it to be sent.

    # What is stored, and where

    History, bookmarks, downloads, open tabs and your settings are held on this \
    device only. They are never uploaded, backed up to a server, or shared with \
    anyone. Deleting the app deletes all of it.

    A private tab keeps its history, cookies and cache in memory alone. Closing \
    the app discards them.

    Clear History & Website Data, in Settings, removes the pages you have \
    visited along with the cookies, caches and local storage of every site. \
    Shred App Data removes everything TitleLess has stored — tabs, history, \
    bookmarks, favourites, downloads list and every setting — and puts it back \
    the way it arrived. Files you have already downloaded are left in Files, \
    where they are yours to delete.

    # What connects to the network

    The pages you choose to visit, and whatever those pages themselves request. \
    A page you open is between you and that site; TitleLess does not add \
    anything to it or report it anywhere.

    Searches go to the search engine you picked in Settings, which is the only \
    thing that engine receives — TitleLess does not attach an identifier.

    Site icons are fetched from the site whose page you are on, over a \
    connection that carries no cookies and keeps nothing on disk.

    Filter lists are downloaded from the addresses shown under Content \
    Filtering, including any you add yourself, and re-checked about once a day. \
    Those requests carry no cookies and say nothing about you beyond the fact \
    that someone asked for a public file.

    # What is not done

    No advertising identifier is read. No location, contacts, photos or \
    microphone access is requested. Choosing a photo or video for the background \
    uses the system picker, which hands over only the item you pick — TitleLess \
    cannot see the rest of your library.

    No crash reports or usage statistics are collected.

    # Blocking

    Ad and tracker blocking runs entirely on this device. The rules are files; \
    the addresses of the pages you visit are matched against them here, and are \
    never sent anywhere to be checked.

    # Children

    TitleLess shows the web, which is not a curated place. It is not directed \
    at children and has no content rating of its own.

    # Changes

    This policy ships with TitleLess. If it changes, it changes in an update, \
    and the version it applies to is the version you are reading it in.
    """

    private static let terms = """
    By using TitleLess you agree to what follows. If you don't, don't use it.

    # What this is

    TitleLess is a web browser. It renders pages using WebKit, the engine iOS \
    provides, and it can block requests and hide elements according to filter \
    lists.

    # The web is not ours

    Pages you visit belong to the people who publish them, and are subject to \
    their own terms. TitleLess is not affiliated with, endorsed by, or \
    responsible for any site you open in it, and displaying a site is not a \
    claim about that site.

    # Filter lists

    The blocking rules are third-party data, maintained by people unconnected \
    to TitleLess. They can be wrong: a rule can break a page, and a page can \
    survive a rule. Lists you add yourself are your responsibility — a filter \
    list can hide or unhide anything on any page you visit, so only subscribe \
    to lists from a source you trust.

    # Use it lawfully

    You are responsible for what you do with it, including complying with the \
    terms of the sites you visit and with the law where you are.

    # No warranty

    Provided as is, without warranty of any kind. To the fullest extent the law \
    allows, the developer is not liable for any loss arising from its use — \
    including lost data, a page that failed to load, or a site that behaved \
    differently than it would in another browser.

    # Open-source components

    TitleLess is built on open-source software, listed with its licences under \
    Licences. Those licences govern those components and nothing here \
    limits the rights they grant you.
    """
}


private extension UIFont {
    /// Bold, while still scaling with the reader's text size — `boldSystemFont`
    /// would pin it to one size and stop tracking Dynamic Type.
    var bold: UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
