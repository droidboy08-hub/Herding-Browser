import UIKit

/// How Home behaves, as distinct from what it looks like.
///
/// Four switches that answer the same question from different angles — what
/// Home shows when it opens, and how you get to it. They sat loose on the
/// settings card between *Buttons* and *Appearance*, which put the mechanics of
/// one screen in the middle of the app's looks. Together behind one row they
/// read as a set, and the section above them stays short.
///
/// Pairs with *Buttons*: that one decides what is on Home, this one decides how
/// Home acts.
final class HomeBehaviourViewController: UIViewController {

    private enum Row {
        case toggle(String, isOn: () -> Bool, set: (Bool) -> Void)
        /// A row with a menu on its right-hand side, for a setting with more
        /// than two answers.
        case topStrip
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    private var rows: [Row] {
        [
            .toggle("Favourites",
                    isOn: { Settings.showFavourites },
                    set: { Settings.showFavourites = $0 }),
            .toggle("Always show panel",
                    isOn: { Settings.startBoxShowsPanel },
                    set: { Settings.startBoxShowsPanel = $0 }),
            .toggle("Auto-open keyboard",
                    isOn: { Settings.autoOpenKeyboard },
                    set: { Settings.autoOpenKeyboard = $0 }),
            .toggle("Open Home by swiping down",
                    isOn: { Settings.swipeOpensStartBox },
                    set: { on in
                        Settings.swipeOpensStartBox = on
                        // The capsule's tap changes with it — see `swipeOpensStartBox`.
                        NotificationCenter.default.post(name: .swipeBindingChanged, object: nil)
                    }),
            .topStrip,
        ]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home Behaviour"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
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

extension HomeBehaviourViewController: UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = UIListContentConfiguration.cell()
        cell.selectionStyle = .none

        switch rows[indexPath.row] {
        case .toggle(let title, let isOn, let set):
            cfg.text = title
            let toggle = UISwitch()
            toggle.isOn = isOn()
            toggle.addAction(UIAction { _ in set(toggle.isOn) }, for: .valueChanged)
            cell.accessoryView = toggle

        case .topStrip:
            cfg.text = "Top Strip"
            let button = UIButton(type: .system)
            button.showsMenuAsPrimaryAction = true
            applyTopStripMode(to: button)
            cell.accessoryView = button
        }

        cell.contentConfiguration = cfg
        return cell
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "The strip across the top of a page, painted with that page's own "
        + "colour. Hidden, the page scrolls under the notch."
    }

    /// Name the chosen mode on the button and build the menu that changes it.
    /// Called again on the same button once one is picked.
    private func applyTopStripMode(to button: UIButton) {
        let current = Settings.topStripMode
        button.setTitle(current.name, for: .normal)
        button.sizeToFit()
        button.superview?.setNeedsLayout()

        button.menu = UIMenu(title: "", children: Settings.TopStripMode.allCases.map { mode in
            UIAction(title: mode.name, state: mode == current ? .on : .off) {
                [weak self, weak button] _ in
                Settings.topStripMode = mode
                guard let button else { return }
                self?.applyTopStripMode(to: button)
            }
        })
    }
}
