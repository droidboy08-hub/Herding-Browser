import UIKit

/// A second glass card that appears *under* the start box for History or
/// Settings — same material, radius, border and shadow as the start box.
/// Fixed height; its content scrolls inside.
final class StartPanelView: UIView {

    enum Mode { case history, settings }

    var onOpenURL: ((URL) -> Void)?
    var onCloseAllTabs: (() -> Void)?
    var onClearWebsiteData: (() -> Void)?
    var onClose: (() -> Void)?

    private(set) var mode: Mode = .history

    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let shadowHost = UIView()
    private let titleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)

    private var entries: [HistoryEntry] = []

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        backgroundColor = .clear

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.backgroundColor = .clear
        shadowHost.layer.shadowColor = UIColor.black.cgColor
        shadowHost.layer.shadowOpacity = 0.22
        shadowHost.layer.shadowRadius = 30
        shadowHost.layer.shadowOffset = CGSize(width: 0, height: 14)
        addSubview(shadowHost)

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 28
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.layer.borderWidth = 1
        card.layer.borderColor = glassEdgeColor()
        addSubview(card)

        let content = card.contentView

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.rounded(20, .bold)
        titleLabel.textColor = .label
        content.addSubview(titleLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        content.addSubview(closeButton)

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .singleLine
        table.separatorInset = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        table.showsVerticalScrollIndicator = false
        table.rowHeight = 58
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        content.addSubview(table)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),

            shadowHost.topAnchor.constraint(equalTo: card.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),

            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),

            table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: StartPanelView, _) in
            v.card.layer.borderColor = v.glassEdgeColor()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds, cornerRadius: 28).cgPath
    }

    // MARK: - Content

    func show(_ mode: Mode) {
        self.mode = mode
        titleLabel.text = mode == .history ? "History" : "Settings"
        if mode == .history { entries = HistoryStore.shared.entries }
        table.reloadData()
        table.setContentOffset(.zero, animated: false)
    }

    @objc private func closeTapped() { onClose?() }

    private func glassEdgeColor() -> CGColor {
        let dark = traitCollection.userInterfaceStyle == .dark
        return UIColor.white.withAlphaComponent(dark ? 0.16 : 0.6).cgColor
    }

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: d, size: size)
    }
}

// MARK: - Rows

extension StartPanelView: UITableViewDataSource, UITableViewDelegate {

    /// Settings rows, in display order.
    private enum SettingsRow {
        case engine(SearchEngine), clearHistory, clearData, closeTabs, version
    }

    private var settingsRows: [SettingsRow] {
        SearchEngine.allCases.map { .engine($0) } + [.clearHistory, .clearData, .closeTabs, .version]
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        mode == .history ? max(entries.count, 1) : settingsRows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = .clear
        cell.accessoryType = .none
        cell.selectionStyle = .default
        let sel = UIView(); sel.backgroundColor = .quaternarySystemFill
        cell.selectedBackgroundView = sel

        if mode == .history {
            var cfg = UIListContentConfiguration.subtitleCell()
            if entries.isEmpty {
                cfg.text = "No history yet"
                cfg.textProperties.color = .tertiaryLabel
                cell.selectionStyle = .none
            } else {
                let e = entries[indexPath.row]
                cfg.text = e.title.isEmpty ? (e.url.host ?? e.url.absoluteString) : e.title
                let when = Self.relative.localizedString(for: e.date, relativeTo: Date())
                cfg.secondaryText = "\(e.url.host ?? e.url.absoluteString) · \(when)"
                cfg.secondaryTextProperties.color = .secondaryLabel
                cfg.image = UIImage(systemName: "clock")
                cfg.imageProperties.tintColor = .secondaryLabel
            }
            cfg.textProperties.numberOfLines = 1
            cfg.secondaryTextProperties.numberOfLines = 1
            cell.contentConfiguration = cfg
        } else {
            var cfg = UIListContentConfiguration.valueCell()
            switch settingsRows[indexPath.row] {
            case .engine(let engine):
                cfg.text = engine.name
                cell.accessoryType = engine == Settings.searchEngine ? .checkmark : .none
            case .clearHistory:
                cfg.text = "Clear History"; cfg.textProperties.color = .systemRed
            case .clearData:
                cfg.text = "Clear Website Data"; cfg.textProperties.color = .systemRed
            case .closeTabs:
                cfg.text = "Close All Tabs"; cfg.textProperties.color = .systemRed
            case .version:
                cfg.text = "Version"
                let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                cfg.secondaryText = v
                cell.selectionStyle = .none
            }
            cell.contentConfiguration = cfg
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if mode == .history {
            guard !entries.isEmpty else { return }
            onOpenURL?(entries[indexPath.row].url)
        } else {
            switch settingsRows[indexPath.row] {
            case .engine(let engine):
                Settings.searchEngine = engine
                tableView.reloadData()
            case .clearHistory:
                HistoryStore.shared.clear()
                entries = []
            case .clearData:
                onClearWebsiteData?()
            case .closeTabs:
                onCloseAllTabs?()
            case .version:
                break
            }
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard mode == .history, !entries.isEmpty else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { done(false); return }
            HistoryStore.shared.remove(self.entries[indexPath.row])
            self.entries = HistoryStore.shared.entries
            tableView.reloadData()
            done(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }
}
