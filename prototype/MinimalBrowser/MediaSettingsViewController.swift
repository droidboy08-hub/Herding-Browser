import UIKit

/// Per-site display preferences for video sites.
///
/// Separate from Content Filtering on purpose. That screen decides which
/// *blocking* rules exist; this one is about how a page looks once it has
/// loaded — chrome you'd rather not see while watching. Nothing here blocks an
/// ad, and nothing here needs the blocking level to be on.
///
/// Grouped by site rather than by kind of change, because that is how the
/// question arrives: "the bar on this site annoys me", not "hide headers".
final class MediaSettingsViewController: UIViewController {

    /// One switch, and where its state lives.
    private struct Option {
        let title: String
        let subtitle: String?
        let isOn: () -> Bool
        let set: (Bool) -> Void
    }

    private struct Section {
        let title: String
        let footer: String?
        let options: [Option]
    }

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private var sections: [Section] = []
    private var storeObserver: NSObjectProtocol?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Media"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        sections = buildSections()

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

        // A switch here can turn a filter list on, and that list downloads —
        // so the rows follow the store rather than assuming the change stuck.
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

    private func buildSections() -> [Section] {
        [
            Section(
                title: "YouTube",
                footer: "These change how the site looks on this device. Hiding "
                      + "Shorts switches on the community filter list for them, "
                      + "which is fetched the first time you turn it on.",
                options: [
                    Option(title: "Hide the bar over the video",
                           subtitle: "The strip with the logo, search and menu "
                                   + "that stays pinned while you scroll.",
                           isOn: { Settings.hideVideoTopBar },
                           set: { on in
                               Settings.hideVideoTopBar = on
                               // Injected scripts are rebuilt from settings, and
                               // apply from the next page load.
                               NotificationCenter.default.post(name: .mediaSettingsChanged,
                                                               object: nil)
                           }),
                    Option(title: "Hide Shorts",
                           subtitle: "Removes the Shorts shelf and player.",
                           isOn: { [weak self] in self?.isShortsListEnabled ?? false },
                           set: { [weak self] on in self?.setShortsList(enabled: on) }),
                    Option(title: "Highest available quality",
                           subtitle: "Plays at the best quality the video offers "
                                   + "instead of one picked for your connection. "
                                   + "Uses more data.",
                           isOn: { Settings.preferHighestQuality },
                           set: { on in
                               Settings.preferHighestQuality = on
                               NotificationCenter.default.post(name: .mediaSettingsChanged,
                                                               object: nil)
                           }),
                ]),
        ]
    }

    // MARK: - Shorts, via the filter catalogue

    /// The catalogue already carries a maintained list for this, so the switch
    /// drives that rather than duplicating its rules here. It stays in step with
    /// the same switch in Content Filtering because both read the one store.
    private var shortsList: CatalogFilterList? {
        FilterListCatalog.entries.first { $0.title.localizedCaseInsensitiveContains("shorts") }
    }

    private var isShortsListEnabled: Bool {
        guard let shortsList else { return false }
        return CustomFilterListStore.shared.isEnabled(catalogID: shortsList.id)
    }

    private func setShortsList(enabled: Bool) {
        guard let shortsList else { return }
        Task { @MainActor in
            do {
                try await CustomFilterListStore.shared.setEnabled(enabled, catalogEntry: shortsList)
            } catch {
                let alert = UIAlertController(
                    title: "Couldn't turn that on",
                    message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            table.reloadData()
        }
    }
}

// MARK: - Table

extension MediaSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].options.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let option = sections[indexPath.section].options[indexPath.row]

        var cfg = UIListContentConfiguration.subtitleCell()
        cfg.text = option.title
        cfg.secondaryText = option.subtitle
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.secondaryTextProperties.numberOfLines = 2
        cell.contentConfiguration = cfg
        cell.selectionStyle = .none

        let toggle = UISwitch()
        toggle.isOn = option.isOn()
        toggle.addAction(UIAction { _ in option.set(toggle.isOn) }, for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }
}
