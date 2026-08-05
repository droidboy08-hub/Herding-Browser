import UIKit

/// Content Filtering: which rule lists are in use, and any the user subscribed
/// to themselves.
///
/// Three kinds of rules, in the order they matter: lists the user subscribed to
/// by URL, maintained lists that can be switched on and off individually, and
/// the user's own rules. The blocking *level*
/// in Privacy decides how hard the rules are applied; this screen decides which
/// rules exist at all.
final class ContentFilteringViewController: UIViewController {

    private enum Section: Int, CaseIterable {
        case subscribed
        case bundled
        case catalog
        case customRules

        var title: String {
            switch self {
            case .subscribed:  return "Custom Filter Lists"
            case .bundled:     return "Built-in Filter Lists"
            case .catalog:     return "Default Filter Lists"
            case .customRules: return "Custom Filters"
            }
        }

        var footer: String? {
            switch self {
            case .subscribed:
                return "Lists maintained by people you trust, fetched from a URL "
                     + "and re-checked once a day. Only subscribe to lists from "
                     + "sources you trust — a filter list can hide or unblock "
                     + "anything on any page you visit."
            case .bundled:
                return "Shipped with the app and always available offline. The "
                     + "unbreak lists are exceptions, and are what stop the "
                     + "others breaking sites."
            case .catalog:
                return "Additional popular community lists, downloaded when you "
                     + "switch them on. Note that enabling too many filters will "
                     + "degrade browsing speeds."
            case .customRules:
                return "Your own rules, applied after every list above."
            }
        }
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var store: CustomFilterListStore { .shared }
    private var storeObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Content Filtering"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = editButtonItem

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

        // Pull to re-fetch every subscribed list, ignoring the once-a-day rule.
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            Task { @MainActor in
                await self?.store.refreshAll()
                refresh.endRefreshing()
            }
        }, for: .valueChanged)
        table.refreshControl = refresh

        storeObserver = NotificationCenter.default.addObserver(
            forName: CustomFilterListStore.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.table.reloadData()
        }
    }

    deinit {
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        table.setEditing(editing, animated: animated)
    }

    // MARK: - Adding a list

    private func presentAddList() {
        let alert = UIAlertController(
            title: "Add Custom Filter List",
            message: "Enter the URL of a filter list. It is fetched now and "
                   + "re-checked once a day.\n\nOnly subscribe to lists from "
                   + "sources you trust.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/list.txt"
            field.keyboardType = .URL
            field.textContentType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self] _ in
            guard let self,
                  let text = alert.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            // A bare host is what people type; assume https rather than failing.
            let normalized = text.contains("://") ? text : "https://\(text)"
            guard let url = URL(string: normalized) else {
                showFailure("That isn't a URL.")
                return
            }
            Task { @MainActor in
                do {
                    try await self.store.add(url: url)
                    self.table.reloadData()
                } catch {
                    self.showFailure(error.localizedDescription)
                }
            }
        })
        present(alert, animated: true)
    }

    private func showFailure(_ message: String) {
        let alert = UIAlertController(title: "Couldn't add that list",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentCustomRules() {
        let editor = CustomFiltersViewController(rules: Settings.customFilters) { rules in
            guard rules != Settings.customFilters else { return }
            Settings.customFilters = rules
            NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
        }
        present(UINavigationController(rootViewController: editor), animated: true)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    /// How long ago, in words. A fetch that just finished reads "just now" —
    /// `RelativeDateTimeFormatter` renders that moment as "in 0s", which looks
    /// like a bug and points at the future.
    private static func age(of date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed >= 60 else { return "just now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Table

extension ContentFilteringViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .subscribed:  return store.subscribed.count + 1        // + the add row
        case .bundled:     return FilterListSource.allCases.count
        case .catalog:     return FilterListCatalog.entries.count + 1  // + Update Lists
        case .customRules: return 1
        case .none:        return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .default

        switch Section(rawValue: indexPath.section) {
        case .subscribed:
            guard indexPath.row < store.subscribed.count else {
                var cfg = UIListContentConfiguration.cell()
                cfg.text = "Add Custom Filter List"
                cfg.textProperties.color = .tintColor
                cell.contentConfiguration = cfg
                return cell
            }
            let list = store.subscribed[indexPath.row]
            var cfg = UIListContentConfiguration.subtitleCell()
            cfg.text = list.title
            switch list.status {
            case .downloaded(let date):
                cfg.secondaryText = "\(list.ruleCount) rules · updated \(Self.age(of: date))\n"
                                  + list.url.absoluteString
            case .failed(let reason):
                cfg.secondaryText = "Update failed: \(reason)\n" + list.url.absoluteString
                cfg.secondaryTextProperties.color = .systemRed
            case .pending:
                cfg.secondaryText = "Pending download\n" + list.url.absoluteString
            }
            cfg.secondaryTextProperties.numberOfLines = 3
            cell.contentConfiguration = cfg
            cell.accessoryView = toggle(isOn: list.isEnabled) { [weak self] on in
                self?.store.setEnabled(on, for: list)
            }
            cell.selectionStyle = .none

        case .bundled:
            let source = FilterListSource.allCases[indexPath.row]
            var cfg = UIListContentConfiguration.subtitleCell()
            cfg.text = source.displayName
            cfg.secondaryText = source.summary
            cfg.secondaryTextProperties.numberOfLines = 2
            cfg.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = cfg
            cell.accessoryView = toggle(isOn: source.isEnabled) { on in
                source.setEnabled(on)
                NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
            }
            cell.selectionStyle = .none

        case .catalog:
            guard indexPath.row > 0 else {
                var cfg = UIListContentConfiguration.cell()
                cfg.text = "Update Lists"
                cfg.textProperties.color = .tintColor
                cfg.image = UIImage(systemName: "arrow.triangle.2.circlepath")
                cfg.imageProperties.tintColor = .tintColor
                cell.contentConfiguration = cfg
                return cell
            }
            let entry = FilterListCatalog.entries[indexPath.row - 1]
            let downloaded = store.entry(forCatalogID: entry.id)
            var cfg = UIListContentConfiguration.subtitleCell()
            cfg.text = entry.title
            // The list's own name below ours, unless something more urgent —
            // a failed download — needs the line.
            if let downloaded, case .failed(let reason) = downloaded.status, downloaded.isEnabled {
                cfg.secondaryText = "\(entry.desc) · couldn't update: \(reason)"
                cfg.secondaryTextProperties.color = .systemRed
            } else {
                cfg.secondaryText = entry.desc
                cfg.secondaryTextProperties.color = .secondaryLabel
            }
            cfg.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = cfg
            cell.accessoryView = toggle(isOn: downloaded?.isEnabled ?? false) { [weak self] on in
                self?.setCatalogList(entry, enabled: on)
            }
            cell.selectionStyle = .none

        case .customRules:
            var cfg = UIListContentConfiguration.valueCell()
            cfg.text = "Edit Custom Filters"
            let count = Settings.customFilters
                .split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .count
            cfg.secondaryText = count == 0 ? "None" : "\(count) rules"
            cell.contentConfiguration = cfg
            cell.accessoryType = .disclosureIndicator

        case .none:
            break
        }
        return cell
    }

    /// A switch that reports back rather than mutating anything itself, so the
    /// row's model stays the single source of truth.
    private func toggle(isOn: Bool, action: @escaping (Bool) -> Void) -> UISwitch {
        let control = UISwitch()
        control.isOn = isOn
        control.addAction(UIAction { _ in action(control.isOn) }, for: .valueChanged)
        return control
    }

    /// Switching a catalogue list on downloads it, which can fail — so the row
    /// goes back to off and says why, rather than claiming a list is active when
    /// there are no rules behind it.
    private func setCatalogList(_ entry: CatalogFilterList, enabled: Bool) {
        Task { @MainActor in
            do {
                try await store.setEnabled(enabled, catalogEntry: entry)
            } catch {
                showFailure(error.localizedDescription)
            }
            table.reloadData()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section) {
        case .subscribed where indexPath.row == store.subscribed.count:
            presentAddList()
        case .catalog where indexPath.row == 0:
            Task { @MainActor in
                await store.refreshAll()
                table.reloadData()
            }
        case .customRules:
            presentCustomRules()
        default:
            break
        }
    }

    // Only lists the user added can be removed; catalogue and built-in lists are
    // switched off instead, and the add row isn't a list at all.
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        Section(rawValue: indexPath.section) == .subscribed
            && indexPath.row < store.subscribed.count
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, indexPath.row < store.subscribed.count else { return }
        store.remove(store.subscribed[indexPath.row])
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
