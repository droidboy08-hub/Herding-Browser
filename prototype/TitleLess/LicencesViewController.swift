import UIKit

/// The third-party work this browser is built on, and the full text of every
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
final class LicencesViewController: UIViewController {

    private struct Component {
        let name: String
        let licence: String
        let detail: String
    }

    private let components: [Component] = [
        Component(
            name: "adblock-rust",
            licence: "MPL-2.0",
            detail: "Brave Software. The filter engine: it parses the lists, "
                  + "answers whether a request matches, and converts rules into "
                  + "the declarative form WebKit compiles. Built as a static "
                  + "library and linked into the app."),
        Component(
            name: "Filter lists — supplemental, mobile, first-party, CNAME, site fixes, cookie notices",
            licence: "MPL-2.0",
            detail: "The Brave Software adblock-lists project and its "
                  + "contributors. Bundled unmodified as data; the app renames "
                  + "them for what they do rather than whose they are."),
        Component(
            name: "Filter list catalogue",
            licence: "MPL-2.0",
            detail: "The adblock-resources project. The list of community "
                  + "filter lists offered under Content Filtering, with the "
                  + "addresses they are fetched from."),
        Component(
            name: "EasyList, EasyPrivacy",
            licence: "GPL-3.0 / CC BY-SA 3.0",
            detail: "The EasyList authors. Bundled unmodified as data."),
        Component(
            name: "uAssets — core ad filters and community site fixes",
            licence: "GPL-3.0",
            detail: "The uBlock Origin contributors. Neither list ships inside "
                  + "this app: both are subscriptions, downloaded to the device "
                  + "on first launch and re-checked daily, and either can be "
                  + "turned off under Content Filtering."),
        Component(
            name: "Scriptlet resources",
            licence: "MPL-2.0, with individual scriptlets under MIT and BSD",
            detail: "The adblock-resources project, including work from "
                  + "mozilla/video-bg-play and pixeltris/TwitchAdSolutions. "
                  + "Verified free of GPL-licensed code before bundling, since "
                  + "these ship compiled into the binary."),
        Component(
            name: "Scriptlets written for this app",
            licence: "Same terms as this app",
            detail: "Independent implementations of the documented behaviour of "
                  + "the scriptlets the filter lists name — written from the "
                  + "specifications rather than derived from uBlock Origin's "
                  + "library, which is GPL-3.0 and cannot ship in an App Store "
                  + "binary."),
        Component(
            name: "WebKit",
            licence: "System framework",
            detail: "Apple. Renders every page, and enforces the compiled "
                  + "blocking rules."),
        Component(
            name: "SQLite",
            licence: "Public domain",
            detail: "D. Richard Hipp and contributors, via the system library. "
                  + "Stores history on this device."),
    ]

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Licences"
        view.backgroundColor = .systemBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

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

        text.append(NSAttributedString(
            string: "This browser blocks ads and trackers using filter lists and "
                  + "an engine written by other people. Their work is credited "
                  + "below, with the licence it carries.\n\n",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .body),
                         .foregroundColor: UIColor.label]))

        for component in components {
            text.append(NSAttributedString(
                string: "\(component.name)\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline),
                             .foregroundColor: UIColor.label]))
            text.append(NSAttributedString(
                string: "\(component.licence)\n\(component.detail)\n\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .subheadline),
                             .foregroundColor: UIColor.secondaryLabel]))
        }

        text.append(NSAttributedString(
            string: "\nThe licences in full\n\n",
            attributes: [.font: UIFont.preferredFont(forTextStyle: .title3),
                         .foregroundColor: UIColor.label]))

        for licence in Self.licences {
            text.append(NSAttributedString(
                string: "\(licence.title)\n\n",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .headline),
                             .foregroundColor: UIColor.label]))
            text.append(NSAttributedString(
                string: licence.body + "\n\n",
                attributes: [.font: UIFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                             .foregroundColor: UIColor.secondaryLabel]))
        }
        return text
    }

    private struct Licence {
        let title: String
        let body: String
    }

    /// Every distinct licence the shipped components are under, in full.
    ///
    /// The long ones are bundled as files rather than pasted into the binary as
    /// string literals: they have to be reproducible verbatim, and a file can be
    /// diffed against the canonical one. The two short ones are here because a
    /// file for eleven lines is more moving parts than it is worth.
    private static let licences: [Licence] = [
        Licence(title: "Mozilla Public License 2.0",
                body: bundled("MPL-2.0", fallback: "https://mozilla.org/MPL/2.0/")),
        Licence(title: "GNU General Public License v3.0",
                body: bundled("GPL-3.0", fallback: "https://www.gnu.org/licenses/gpl-3.0.txt")),
        Licence(title: "Creative Commons Attribution-ShareAlike 3.0 Unported",
                body: bundled("CC-BY-SA-3.0",
                              fallback: "https://creativecommons.org/licenses/by-sa/3.0/legalcode")),
        Licence(title: "MIT License", body: mit),
        Licence(title: "BSD 3-Clause License", body: bsd),
    ]

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
