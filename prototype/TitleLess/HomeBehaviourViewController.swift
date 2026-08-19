import UIKit

/// How Home behaves, as distinct from what it looks like.
///
/// Three switches that answer the same question from different angles — what
/// Home shows when it opens, and how you get to it. They sat loose on the
/// settings card between *Buttons* and *Appearance*, which put the mechanics of
/// one screen in the middle of the app's looks. Together behind one row they
/// read as a set, and the section above them stays short.
///
/// Pairs with *Buttons*: that one decides what is on Home, this one decides how
/// Home acts.
final class HomeBehaviourViewController: UIViewController {

    private struct Row {
        let title: String
        let isOn: () -> Bool
        let set: (Bool) -> Void
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    private var rows: [Row] {
        [
            Row(title: "Favourites",
                isOn: { Settings.showFavourites },
                set: { Settings.showFavourites = $0 }),
            Row(title: "Always show panel",
                isOn: { Settings.startBoxShowsPanel },
                set: { Settings.startBoxShowsPanel = $0 }),
            Row(title: "Open Home by swiping down",
                isOn: { Settings.swipeOpensStartBox },
                set: { on in
                    Settings.swipeOpensStartBox = on
                    // The capsule's tap changes with it — see `swipeOpensStartBox`.
                    NotificationCenter.default.post(name: .swipeBindingChanged, object: nil)
                }),
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
        let row = rows[indexPath.row]

        var cfg = UIListContentConfiguration.cell()
        cfg.text = row.title
        cell.contentConfiguration = cfg
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = row.isOn()
        toggle.addAction(UIAction { _ in row.set(toggle.isOn) }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }
}
