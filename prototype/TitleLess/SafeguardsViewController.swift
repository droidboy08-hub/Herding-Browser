import UIKit

/// The defences, gathered off the settings card.
///
/// Privacy had grown to ten rows, which is most of a small card spent on
/// switches almost nobody moves twice. What stays behind is the part people
/// actually come to Privacy for: how much to block, and how to forget. The
/// rest — the individual defences, each on by default or deliberately off, each
/// set once and left — lives here.
///
/// "Safeguards" rather than "Advanced", because none of this is advanced. Every
/// one is a plain statement about what the browser refuses to do on your
/// behalf; they are simply not decisions that need re-making from the front
/// page.
final class SafeguardsViewController: UIViewController {

    /// Presented by the browser, which owns the screens these push to.
    var onShowContentFiltering: (() -> Void)?
    var onShowPasswords: (() -> Void)?

    private enum Row {
        case toggle(String, get: () -> Bool, set: (Bool) -> Void)
        case action(String)
    }

    private struct Section {
        let title: String?
        let rows: [Row]
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    private var sections: [Section] {
        // Hidden outright when the device has no passcode set, rather than
        // shown as a switch that cannot do anything. There is nothing to check
        // against on such a device, so the row would be a promise the browser
        // could not keep. Apple hides its own for the same reason.
        let privacyRows: [Row] = BiometricGate.isAvailable
            ? [.toggle("Require \(BiometricGate.displayName) for Private",
                       get: { Settings.requirePrivateAuth },
                       set: { Settings.requirePrivateAuth = $0 })]
            : []

        return [
            Section(title: nil, rows: [
                .toggle("Block fingerprinting",
                        get: { Settings.blockFingerprinting },
                        set: { on in
                            Settings.blockFingerprinting = on
                            NotificationCenter.default.post(name: .contentBlockingChanged,
                                                            object: nil)
                        }),
                .toggle("Block JavaScript",
                        get: { Settings.blockJavaScript },
                        set: { on in
                            Settings.blockJavaScript = on
                            NotificationCenter.default.post(name: .contentBlockingChanged,
                                                            object: nil)
                        }),
                .toggle("Hide cookie notices",
                        get: { Settings.blockCookieNotices },
                        set: { on in
                            Settings.blockCookieNotices = on
                            NotificationCenter.default.post(name: .contentBlockingChanged,
                                                            object: nil)
                        }),
                .toggle("Always block pop-ups",
                        get: { Settings.blockRedirectPages },
                        set: { Settings.blockRedirectPages = $0 }),
                .toggle("HTTPS-Only Mode",
                        get: { Settings.httpsOnly },
                        set: { Settings.httpsOnly = $0 }),
            ] + privacyRows),
            Section(title: nil, rows: [
                .action("Content Filtering"),
                .action("Passwords"),
            ]),
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Safeguards"
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
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - Table

extension SafeguardsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryType = .none
        cell.accessoryView = nil

        var cfg = UIListContentConfiguration.cell()
        switch sections[indexPath.section].rows[indexPath.row] {
        case .toggle(let title, let get, let set):
            cfg.text = title
            let toggle = UISwitch()
            toggle.isOn = get()
            toggle.addAction(UIAction { _ in set(toggle.isOn) }, for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none

        case .action(let title):
            cfg.text = title
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = cfg
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .action(let title) = sections[indexPath.section].rows[indexPath.row] else {
            return
        }
        switch title {
        case "Content Filtering": onShowContentFiltering?()
        case "Passwords":         onShowPasswords?()
        default:
            // Wired by title, so a rename here without one there silently
            // unhooks the row — loud in debug rather than in a bug report.
            assertionFailure("Safeguards row \"\(title)\" has no action")
        }
    }
}
