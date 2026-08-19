import UIKit

/// Choose which buttons sit across the top of the start box.
///
/// Two lists and a drag between them: what's in the row, in the order it's in,
/// and what isn't. There are five buttons and four places, so dragging a fifth
/// into the row pushes the one at the end of it out — the trade happens where
/// you can see it rather than in a dialogue asking you to describe it.
final class StartBoxButtonsViewController: UIViewController {

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    /// Always ends with Settings, whatever was stored.
    ///
    /// Settings is pinned to the last place in the row and cannot be dragged
    /// out of it. It is the way into every other preference, including this
    /// screen — a row it could be removed from is a row that can lock you out
    /// of the only place that puts it back.
    private var chosen: [StartBoxButton] = {
        var stored = Settings.startBoxButtons.filter { $0 != .settings }
        stored.append(.settings)
        return stored
    }()
    /// Everything else. Stored rather than derived, so that each list is a plain
    /// array the table's own move maps onto exactly — a list computed from the
    /// other one can reorder itself under a drag that is still in flight.
    ///
    /// Settings is never in here; it has nowhere else to be.
    private var rest: [StartBoxButton] = StartBoxButton.allCases
        .filter { $0 != .settings && !Settings.startBoxButtons.contains($0) }

    /// Where Settings sits — the end of the row, and the one slot nothing else
    /// may be dropped into.
    private var pinnedIndex: Int { chosen.count - 1 }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Buttons"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        // Permanently editing, which is what puts a reorder grip on every row.
        // Nothing here is deleted or inserted — a button is always in one of the
        // two lists — so the red and green controls are turned off and the rows
        // keep their full width.
        table.setEditing(true, animated: false)
        table.allowsSelectionDuringEditing = false
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func button(at indexPath: IndexPath) -> StartBoxButton {
        indexPath.section == 0 ? chosen[indexPath.row] : rest[indexPath.row]
    }
}

extension StartBoxButtonsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? chosen.count : rest.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "In the Start Box" : "Not Shown"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return "Drag to reorder, or between the lists. "
             + "\(Settings.startBoxButtonCapacity) fit across the top of the box, "
             + "so one too many pushes the last one out.\n\n"
             + "Settings keeps the last place and cannot be moved — it is the "
             + "way back to this screen."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let button = self.button(at: indexPath)
        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = button.name
        cfg.secondaryText = button.detail
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.image = UIImage(systemName: button.symbolName)
        cfg.imageProperties.tintColor = indexPath.section == 0 ? .tintColor : .secondaryLabel
        cell.contentConfiguration = cfg
        cell.shouldIndentWhileEditing = false
        return cell
    }

    // MARK: - Reordering

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        button(at: indexPath) != .settings
    }

    func tableView(_ tableView: UITableView,
                   editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    /// The drag itself is the only control, so the rules live here: the row
    /// can't be emptied, and a drop past the end of a list lands at its end.
    func tableView(_ tableView: UITableView,
                   targetIndexPathForMoveFromRowAt source: IndexPath,
                   toProposedIndexPath proposed: IndexPath) -> IndexPath {
        // An empty row would be a card with nothing on it and no way back.
        if source.section == 0, proposed.section == 1, chosen.count == 1 { return source }

        let last: Int
        if proposed.section == 0 {
            // Never past Settings. It holds the end of the row, so the furthest
            // anything else can land is the slot in front of it.
            if proposed.section == source.section {
                // Within the row the dragged button still occupies a slot of
                // its own, so its own index is available to it.
                last = pinnedIndex - 1
            } else {
                // Arriving from the other list, the row grows by one — but the
                // newcomer still has to come to rest before Settings, and
                // before the slot that would push it straight back out.
                last = min(pinnedIndex, Settings.startBoxButtonCapacity - 2)
            }
        } else if proposed.section == source.section {
            last = rest.count - 1
        } else {
            last = rest.count
        }
        return IndexPath(row: min(proposed.row, max(last, 0)), section: proposed.section)
    }

    func tableView(_ tableView: UITableView,
                   moveRowAt source: IndexPath, to destination: IndexPath) {
        // Mirror exactly what the table has already done to itself.
        let moved = source.section == 0
            ? chosen.remove(at: source.row) : rest.remove(at: source.row)
        if destination.section == 0 {
            chosen.insert(moved, at: min(destination.row, chosen.count))
        } else {
            rest.insert(moved, at: min(destination.row, rest.count))
        }

        // A fifth button dropped into a row that holds four: the one at the end
        // is the one that leaves, and never the one just dropped in — the clamp
        // above is what guarantees that. The table doesn't know about this
        // second move, so it is handed over as its own update rather than as a
        // reload; a reload here throws away the cell the drag is still
        // animating and leaves it stranded above the list.
        // A button too many: the one at the end leaves — but the end is
        // Settings, which never does, so it is the last one in front of it.
        var pushedOut: IndexPath?
        if chosen.count > Settings.startBoxButtonCapacity {
            let evicted = pinnedIndex - 1
            rest.insert(chosen.remove(at: evicted), at: 0)
            pushedOut = IndexPath(row: evicted, section: 0)
        }
        Settings.startBoxButtons = chosen

        DispatchQueue.main.async {
            guard let pushedOut else {
                // Still a repaint: the icon is tinted by which list it is in.
                tableView.reconfigureRows(at: tableView.indexPathsForVisibleRows ?? [])
                return
            }
            tableView.performBatchUpdates {
                tableView.moveRow(at: pushedOut, to: IndexPath(row: 0, section: 1))
            } completion: { _ in
                tableView.reconfigureRows(at: tableView.indexPathsForVisibleRows ?? [])
            }
        }
    }
}
