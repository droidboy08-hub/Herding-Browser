import UIKit

/// The third-party work TitleLess is built on, and the full text of every
/// licence it is carried under.
///
/// The filter lists and the scriptlet resources are other people's work, carried
/// under licences that ask for the notice to travel with them. Product names
/// appear here, as attribution, and nowhere else in the app: a licence grants
/// rights to the work, never to the name — MPL-2.0 says so in as many words
/// (§3.4), and every other licence here takes the same position. So this screen
/// is the one place a project is named, and the app's own list names describe
/// what a list does rather than borrowing whose it is.
///
/// The licence texts are bundled verbatim rather than linked. Several of these
/// licences require the text to accompany the distribution, and a link is not
/// the text — it is a request that the reader go and find it, on a network they
/// may not have, at an address that may not still serve it.
///
/// A list rather than the single scrolling document this used to be. Bundling
/// the texts in full is a requirement; putting all forty thousand words of them
/// between the reader and the credits is not. Every browser that ships this
/// screen does it the same way — a row per component, the text one tap in — and
/// it is the arrangement that makes the attribution legible rather than merely
/// present.
final class LicencesViewController: UIViewController {

    // MARK: - Model

    private enum LicenceID: String, CaseIterable {
        case mpl, gpl, ccBySa, mit, bsd

        var title: String {
            switch self {
            case .mpl:    return "Mozilla Public License 2.0"
            case .gpl:    return "GNU General Public License v3.0"
            case .ccBySa: return "Creative Commons Attribution-ShareAlike 3.0"
            case .mit:    return "MIT License"
            case .bsd:    return "BSD 3-Clause License"
            }
        }

        /// The short form, for the right-hand side of a row.
        var tag: String {
            switch self {
            case .mpl:    return "MPL-2.0"
            case .gpl:    return "GPL-3.0"
            case .ccBySa: return "CC BY-SA 3.0"
            case .mit:    return "MIT"
            case .bsd:    return "BSD 3-Clause"
            }
        }

        var body: String {
            switch self {
            case .mpl:    return LicencesViewController.bundled(
                "MPL-2.0", fallback: "https://mozilla.org/MPL/2.0/")
            case .gpl:    return LicencesViewController.bundled(
                "GPL-3.0", fallback: "https://www.gnu.org/licenses/gpl-3.0.txt")
            case .ccBySa: return LicencesViewController.bundled(
                "CC-BY-SA-3.0",
                fallback: "https://creativecommons.org/licenses/by-sa/3.0/legalcode")
            case .mit:    return LicencesViewController.mit
            case .bsd:    return LicencesViewController.bsd
            }
        }
    }

    private struct Component {
        let name: String
        /// What the row shows on the right. Not always a licence in this list —
        /// a system framework and a public-domain library have no text to carry.
        let tag: String
        /// The licences whose text belongs with this component, if any.
        let licences: [LicenceID]
        let detail: String

        init(name: String, tag: String? = nil,
             licences: [LicenceID] = [], detail: String) {
            self.name = name
            self.tag = tag ?? licences.map(\.tag).joined(separator: ", ")
            self.licences = licences
            self.detail = detail
        }
    }

    private let components: [Component] = [
        Component(
            name: "adblock-rust",
            licences: [.mpl],
            detail: "Brave Software. The filter engine: it parses the lists, "
                  + "answers whether a request matches, and converts rules into "
                  + "the declarative form WebKit compiles. Built as a static "
                  + "library and linked into the app."),
        Component(
            name: "Filter lists",
            licences: [.mpl],
            detail: "Supplemental, mobile, first-party, CNAME, site fixes and "
                  + "cookie notices, from the Brave Software adblock-lists "
                  + "project and its contributors. Bundled unmodified as data; "
                  + "the app renames them for what they do rather than whose "
                  + "they are."),
        Component(
            name: "Filter list catalogue",
            licences: [.mpl],
            detail: "The adblock-resources project. The list of community "
                  + "filter lists offered under Content Filtering, with the "
                  + "addresses they are fetched from."),
        Component(
            name: "EasyList, EasyPrivacy",
            licences: [.gpl, .ccBySa],
            detail: "The EasyList authors. Bundled unmodified as data."),
        Component(
            name: "uAssets",
            licences: [.gpl],
            detail: "Core ad filters and community site fixes, from the uBlock "
                  + "Origin contributors. Neither list ships inside this app: "
                  + "both are subscriptions, downloaded to the device on first "
                  + "launch and re-checked daily, and either can be turned off "
                  + "under Content Filtering."),
        Component(
            name: "Scriptlet resources",
            licences: [.mpl, .mit, .bsd],
            detail: "The adblock-resources project, including work from "
                  + "mozilla/video-bg-play and pixeltris/TwitchAdSolutions. "
                  + "Verified free of GPL-licensed code before bundling, since "
                  + "these ship compiled into the binary."),
        Component(
            name: "Scriptlets written for this app",
            tag: "Same terms as TitleLess",
            detail: "Independent implementations of the documented behaviour of "
                  + "the scriptlets the filter lists name — written from the "
                  + "specifications rather than derived from uBlock Origin's "
                  + "library, which is GPL-3.0 and cannot ship in an App Store "
                  + "binary."),
        Component(
            name: "WebKit",
            tag: "System framework",
            detail: "Apple. Renders every page, and enforces the compiled "
                  + "blocking rules."),
        Component(
            name: "SQLite",
            tag: "Public domain",
            detail: "D. Richard Hipp and contributors, via the system library. "
                  + "Stores history on this device."),
    ]

    // MARK: - Screen

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Licences"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private static func bundled(_ name: String, fallback url: String) -> String {
        guard let file = Bundle.main.url(forResource: name, withExtension: "txt"),
              let text = try? String(contentsOf: file, encoding: .utf8) else {
            return "The full licence text is available at \(url)."
        }
        return text
    }

    private static let mit = """
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
    """

    private static let bsd = """
    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright notice, this
       list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright notice,
       this list of conditions and the following disclaimer in the documentation
       and/or other materials provided with the distribution.

    3. Neither the name of the copyright holder nor the names of its contributors
       may be used to endorse or promote products derived from this software
       without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
    AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
    IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
    DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
    FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
    DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
    SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
    OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
    """
}

// MARK: - Table

extension LicencesViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? components.count : LicenceID.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Built On" : "Licences In Full"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return "Ad and tracker blocking is other people's work. Tap any of these "
             + "for what it does and the licence it carries."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        if indexPath.section == 0 {
            let component = components[indexPath.row]
            content.text = component.name
            content.secondaryText = component.tag
        } else {
            content.text = LicenceID.allCases[indexPath.row].title
            content.secondaryText = LicenceID.allCases[indexPath.row].tag
        }
        // A licence name is long and a tag is short; let the name wrap rather
        // than truncating it, which is the one thing attribution cannot do.
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let screen: LicenceTextViewController
        if indexPath.section == 0 {
            let component = components[indexPath.row]
            screen = LicenceTextViewController(
                title: component.name,
                summary: component.detail,
                sections: component.licences.map { ($0.title, $0.body) })
        } else {
            let licence = LicenceID.allCases[indexPath.row]
            screen = LicenceTextViewController(
                title: licence.tag, summary: nil,
                sections: [(licence.title, licence.body)])
        }
        navigationController?.pushViewController(screen, animated: true)
    }
}

/// One component's credit, or one licence in full.
private final class LicenceTextViewController: UIViewController {

    private let heading: String
    private let summary: String?
    private let sections: [(title: String, body: String)]
    private let textView = UITextView()

    init(title: String, summary: String?, sections: [(String, String)]) {
        self.heading = title
        self.summary = summary
        self.sections = sections.map { (title: $0.0, body: $0.1) }
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = heading
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 32, right: 16)
        textView.attributedText = body()
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func body() -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let summary {
            text.append(NSAttributedString(
                string: summary + "\n\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .callout),
                             .foregroundColor: UIColor.label]))
        }
        for section in sections {
            text.append(NSAttributedString(
                string: section.title + "\n\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline),
                             .foregroundColor: UIColor.label]))
            text.append(NSAttributedString(
                string: section.body + "\n\n",
                attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: UIColor.secondaryLabel]))
        }
        return text
    }
}
