import UIKit

/// The panel mode a start box button opens.
///
/// The two enumerations are separate on purpose: a mode is something the panel
/// can show, a button is something the row can hold, and only the modes reached
/// from that row are in both.
extension StartBoxButton {
    init?(mode: StartPanelView.Mode) {
        switch mode {
        case .tabs:      self = .tabs
        case .downloads: self = .downloads
        case .history:   self = .history
        case .bookmarks: self = .bookmarks
        case .settings:  self = .settings
        }
    }
}

/// A second glass card that appears *under* the start box for Tabs, History or
/// Settings — same material, radius, border and shadow as the start box.
/// Fixed height; its content scrolls inside.
final class StartPanelView: UIView {

    enum Mode { case tabs, downloads, history, bookmarks, settings }

    var onOpenURL: ((URL) -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onCloseAllTabs: (() -> Void)?
    var onClearWebsiteData: (() -> Void)?
    var onOpenDownload: ((DownloadItem) -> Void)?
    var onShowDownloads: (() -> Void)?
    /// Both need a view controller to present from, which a view isn't.
    var onShowContentFiltering: (() -> Void)?
    var onShowMediaSettings: (() -> Void)?
    var onShowAppearance: (() -> Void)?
    var onShowAppIcon: (() -> Void)?
    var onShowStartBoxButtons: (() -> Void)?
    var onShowPasswords: (() -> Void)?
    var onShowLicences: (() -> Void)?
    var onOpenSupport: ((SupportDestination) -> Void)?
    /// Ask before doing something that cannot be undone. A view can't present
    /// an alert, so the browser is handed the question and the consequence.
    var onConfirmDestructive: ((String, String, @escaping () -> Void) -> Void)?
    var onShowLegal: ((LegalDocument) -> Void)?
    /// The tab box is where private browsing is entered and left, so the two tab
    /// sets are a switch away from each other rather than a mode buried in
    /// settings — the same place other browsers put it.
    var onTogglePrivate: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    /// Which set of tabs is on screen. Set by the browser after the switch has
    /// actually happened, so the button can never claim a state the app isn't in.
    var isPrivateBrowsing = false {
        didSet { updatePrivateButton() }
    }

    /// Injected by the browser from the active profile — a private profile hands
    /// over its own in-memory store instead.
    var history: SQLiteHistory?

    private(set) var mode: Mode = .tabs

    /// Not interactive: the panel is a surface things sit on, and glass that
    /// flexed under every tap on a settings row would be noise.
    private let card = GlassSurface.makeView(radius: 28)
    private let shadowHost = UIView()
    private let titleLabel = UILabel()
    private let gridButton = UIButton(type: .system)
    private let privateButton = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let searchButton = UIButton(type: .system)
    private let clearHistoryButton = TrashIconView(size: 20, strokeWidth: 1.5)
    private let closeButton = ExpandedHitButton(type: .system)
    private let searchField = UITextField()
    private let searchBar = UIView()
    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private lazy var collection = UICollectionView(frame: .zero,
                                                   collectionViewLayout: makeLayout(grid: isGrid))

    private var entries: [HistoryEntry] = []
    private var bookmarks: [Bookmark] = []
    private var downloads: [DownloadItem] = []
    private var downloadQuery = ""
    private var tabs: [Tab] = []
    private var currentTabID: UUID?
    private var isGrid = Settings.tabsInGridView
    private var tableTop: NSLayoutConstraint!
    private var searchBarHeight: NSLayoutConstraint!

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
        GlassSurface.applyFallbackShadow(to: shadowHost, opacity: 0.22, radius: 30,
                                         offset: CGSize(width: 0, height: 14))
        addSubview(shadowHost)

        card.translatesAutoresizingMaskIntoConstraints = false
        GlassSurface.applyFallbackEdge(to: card, color: glassEdgeColor())
        addSubview(card)

        let content = card.contentView

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Self.rounded(20, .bold)
        titleLabel.textColor = .label
        content.addSubview(titleLabel)

        gridButton.setImage(UIImage(systemName: isGrid ? "list.bullet" : "square.grid.2x2"), for: .normal)
        gridButton.tintColor = .secondaryLabel
        gridButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .regular), forImageIn: .normal)
        gridButton.addTarget(self, action: #selector(toggleGrid), for: .touchUpInside)

        privateButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .regular), forImageIn: .normal)
        privateButton.addTarget(self, action: #selector(togglePrivate), for: .touchUpInside)
        updatePrivateButton()

        // Downloads header controls: retry sits left of search, both left of close.
        retryButton.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        searchButton.setImage(UIImage(systemName: "magnifyingglass"), for: .normal)
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        
        clearHistoryButton.addTarget(self, action: #selector(clearHistoryTapped), for: .touchUpInside)
        clearHistoryButton.tintColor = .secondaryLabel
        clearHistoryButton.isHidden = true
        
        for b in [retryButton, searchButton] {
            b.tintColor = .secondaryLabel
            b.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
            b.isHidden = true
        }

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold), forImageIn: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [privateButton, gridButton, clearHistoryButton, retryButton, searchButton, closeButton])
        buttons.axis = .horizontal
        buttons.spacing = 18
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(buttons)

        // Filter field, revealed by the header's search icon. Collapsed to zero
        // height when hidden so the list keeps the full card.
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.clipsToBounds = true
        content.addSubview(searchBar)

        let pill = UIView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.backgroundColor = .quaternarySystemFill
        pill.layer.cornerRadius = 17
        pill.layer.cornerCurve = .continuous
        searchBar.addSubview(pill)

        let glass = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.tintColor = .secondaryLabel
        glass.contentMode = .scaleAspectFit
        pill.addSubview(glass)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search downloads"
        searchField.font = .systemFont(ofSize: 15)
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.clearButtonMode = .whileEditing
        searchField.returnKeyType = .done
        searchField.delegate = self
        searchField.addTarget(self, action: #selector(searchChanged), for: .editingChanged)
        pill.addSubview(searchField)

        searchBarHeight = searchBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            searchBarHeight,
            pill.leadingAnchor.constraint(equalTo: searchBar.leadingAnchor, constant: 22),
            pill.trailingAnchor.constraint(equalTo: searchBar.trailingAnchor, constant: -22),
            pill.topAnchor.constraint(equalTo: searchBar.topAnchor, constant: 6),
            pill.heightAnchor.constraint(equalToConstant: 34),

            glass.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
            glass.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 15),
            glass.heightAnchor.constraint(equalToConstant: 15),

            searchField.leadingAnchor.constraint(equalTo: glass.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
            searchField.topAnchor.constraint(equalTo: pill.topAnchor),
            searchField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = .clear
        table.separatorStyle = .singleLine
        // The grouped style reserves a lot of room above each header, which on a
        // card this size reads as the sections drifting apart. Cut to nothing
        // here and given back deliberately in `heightForHeaderInSection`.
        table.sectionHeaderTopPadding = 0
        table.showsVerticalScrollIndicator = false
        table.rowHeight = 58
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.register(DownloadCell.self, forCellReuseIdentifier: DownloadCell.reuseID)
        content.addSubview(table)

        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = .clear
        collection.showsVerticalScrollIndicator = false
        collection.dataSource = self
        collection.delegate = self
        collection.register(TabItemCell.self, forCellWithReuseIdentifier: TabItemCell.reuseID)
        content.addSubview(collection)

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

            buttons.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),

            searchBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            table.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 4),
            table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            collection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            collection.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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

    func setTabs(_ tabs: [Tab], current: UUID?) {
        self.tabs = tabs
        self.currentTabID = current
        guard mode == .tabs else { return }
        collection.reloadData()
    }

    /// Filled mask while private, outline while not — the state has to be
    /// readable at a glance, because everything about what gets stored depends
    /// on it.
    private func updatePrivateButton() {
        let name = isPrivateBrowsing ? "theatermasks.fill" : "theatermasks"
        privateButton.setImage(UIImage(systemName: name), for: .normal)
        privateButton.tintColor = isPrivateBrowsing ? .tintColor : .secondaryLabel
        privateButton.accessibilityLabel = isPrivateBrowsing
            ? "Leave private browsing" : "Private browsing"
        if mode == .tabs {
            titleLabel.text = isPrivateBrowsing ? "Private Tabs" : "Tabs"
        }
    }

    @objc private func togglePrivate() {
        // Reported, not applied: the browser owns the profile swap and sets
        // `isPrivateBrowsing` back once it has happened.
        onTogglePrivate?(!isPrivateBrowsing)
    }

    func show(_ mode: Mode) {
        self.mode = mode
        switch mode {
        case .tabs:      titleLabel.text = isPrivateBrowsing ? "Private Tabs" : "Tabs"
        case .downloads: titleLabel.text = "Downloads"; refreshDownloads()
        case .history:   titleLabel.text = "History"; entries = history?.recentEntries(grouping: Settings.groupRepeatedVisits) ?? []
        case .bookmarks: titleLabel.text = "Bookmarks"; bookmarks = BookmarkStore.shared.bookmarks
        case .settings:  titleLabel.text = "Settings"
        }
        let showingTabs = mode == .tabs
        let showingDownloads = mode == .downloads
        let showingHistory = mode == .history
        gridButton.isHidden = !showingTabs
        privateButton.isHidden = !showingTabs
        clearHistoryButton.isHidden = !showingHistory
        retryButton.isHidden = !showingDownloads
        searchButton.isHidden = !showingDownloads
        collection.isHidden = !showingTabs
        table.isHidden = showingTabs
        table.rowHeight = showingDownloads ? 66 : 58

        // The filter only belongs to Downloads; leaving it open across a mode
        // switch would filter a list it doesn't apply to.
        if !showingDownloads { collapseSearch() }

        // Both, every time, even though only one is visible.
        //
        // Hiding a view does not stop it laying out, and `togglePanel` forces a
        // layout pass while it animates. A table left unreloaded still holds the
        // index paths of the mode it was last showing, so it asks for row 39 of
        // a History list while the data source has already switched to answering
        // as Tabs — and the subscript traps. Reloading the one going out of
        // sight is what keeps its cached counts honest.
        collection.reloadData()
        table.reloadData()
        if showingTabs {
            collection.setContentOffset(.zero, animated: false)
        } else {
            table.setContentOffset(.zero, animated: false)
        }
    }

    // MARK: - History

    /// Re-read the store. Safe to call at any time — it's a no-op unless History
    /// is the visible mode.
    func historyChanged() {
        guard mode == .history else { return }
        entries = history?.recentEntries(grouping: Settings.groupRepeatedVisits) ?? []
        table.reloadData()
    }

    // MARK: - Bookmarks

    /// As above, for the kept pages. History also draws a bookmark on any row
    /// it has kept, so a change repaints that list too.
    func bookmarksChanged() {
        switch mode {
        case .bookmarks:
            bookmarks = BookmarkStore.shared.bookmarks
            table.reloadData()
        case .history:
            table.reloadData()
        default:
            break
        }
    }

    // MARK: - Downloads

    /// Pull the current list and apply the filter. Called on every progress tick,
    /// so it reloads rows rather than rebuilding the table.
    private func refreshDownloads() {
        let all = DownloadManager.shared.items
        let q = downloadQuery.trimmingCharacters(in: .whitespaces).lowercased()
        downloads = q.isEmpty ? all : all.filter { $0.filename.lowercased().contains(q) }
        // Retry is only meaningful when something actually failed.
        retryButton.isEnabled = all.contains { $0.state == .failed }
        retryButton.tintColor = retryButton.isEnabled ? .secondaryLabel : .quaternaryLabel
        if DownloadManager.shared.hasActiveDownloads {
            retryButton.imageView?.startSpinning()
        } else {
            retryButton.imageView?.stopSpinning()
        }
    }

    /// Live progress arrived — repaint without disturbing the scroll position.
    func downloadsChanged() {
        guard mode == .downloads else { return }
        let before = downloads.count
        refreshDownloads()
        if downloads.count == before {
            let offset = table.contentOffset
            table.reloadData()
            table.setContentOffset(offset, animated: false)
        } else {
            table.reloadData()
        }
    }

    @objc private func retryTapped() {
        // Same flourish as the page refresh button — it's the same gesture.
        retryButton.imageView?.spinOnce()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DownloadManager.shared.retryAllFailed()
        downloadsChanged()
    }

    @objc private func searchTapped() {
        searchBarHeight.constant == 0 ? expandSearch() : collapseSearch()
    }

    private func expandSearch() {
        searchBarHeight.constant = 46
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.3, options: [.curveEaseOut]) {
            self.searchButton.tintColor = .tintColor
            self.layoutIfNeeded()
        } completion: { _ in
            self.searchField.becomeFirstResponder()
        }
    }

    private func collapseSearch() {
        guard searchBarHeight.constant != 0 else { return }
        searchField.resignFirstResponder()
        searchField.text = ""
        downloadQuery = ""
        searchBarHeight.constant = 0
        UIView.animate(withDuration: 0.2) {
            self.searchButton.tintColor = .secondaryLabel
            self.layoutIfNeeded()
        }
        if mode == .downloads { refreshDownloads(); table.reloadData() }
    }

    @objc private func searchChanged() {
        downloadQuery = searchField.text ?? ""
        refreshDownloads()
        table.reloadData()
    }

    @objc private func toggleGrid() {
        isGrid.toggle()
        Settings.tabsInGridView = isGrid
        gridButton.setImage(UIImage(systemName: isGrid ? "list.bullet" : "square.grid.2x2"),
                            for: .normal)
        for cell in collection.visibleCells {
            guard let tabCell = cell as? TabItemCell,
                  let indexPath = collection.indexPath(for: cell) else { continue }
            let tab = tabs[indexPath.item]
            tabCell.configure(with: tab, isCurrent: tab.id == currentTabID, grid: isGrid)
        }
        collection.setCollectionViewLayout(makeLayout(grid: isGrid), animated: true)
    }

    /// One column of rows, or a two-column grid of cards.
    private func makeLayout(grid: Bool) -> UICollectionViewCompositionalLayout {
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(grid ? 0.5 : 1.0),
            heightDimension: .fractionalHeight(1.0)))
        item.contentInsets = grid
            ? NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
            : .zero
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1.0),
                              heightDimension: .absolute(grid ? 176 : 62)),
            subitems: grid ? [item, item] : [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = grid
            ? NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 12, trailing: 16)
            : NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0)
        return UICollectionViewCompositionalLayout(section: section)
    }

    @objc private func closeTapped() { onClose?() }

    @objc private func clearHistoryTapped() {
        clearHistoryButton.playAnimation { [weak self] in
            self?.history?.clear()
            self?.entries = []
            self?.table.reloadData()
        }
    }

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

// MARK: - Tabs (collection)

extension StartPanelView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        tabs.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell {
        let cell = cv.dequeueReusableCell(withReuseIdentifier: TabItemCell.reuseID,
                                          for: indexPath) as! TabItemCell
        let tab = tabs[indexPath.item]
        cell.configure(with: tab, isCurrent: tab.id == currentTabID, grid: isGrid)
        cell.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
        return cell
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelectTab?(tabs[indexPath.item].id)
    }
}

// MARK: - History / Settings (table)

extension StartPanelView: UITableViewDataSource, UITableViewDelegate {

    /// One settings row. `.soon` rows are placeholders for features that don't
    /// exist yet — shown greyed out and non-selectable so the structure is real
    /// but nothing pretends to work.
    private enum SettingsRow {
        case searchEnginePicker
        case startPagePicker
        case blockingLevelPicker
        case toggle(String, get: () -> Bool, set: (Bool) -> Void)
        case slider(String, get: () -> Float, set: (Float) -> Void)
        case action(String)
        case destructive(String)
        case version
    }

    private struct SettingsSection {
        let title: String?
        let rows: [SettingsRow]
        /// Explanatory line under the section, as in iOS Settings. Used where a
        /// control's effect isn't obvious from its label.
        var footer: String? = nil
    }

    private var settingsSections: [SettingsSection] {
        [
            SettingsSection(title: "General", rows: [
                .searchEnginePicker,
                .startPagePicker,
                .toggle("Allow pinch to zoom",
                        get: { Settings.allowZoom },
                        set: { Settings.allowZoom = $0 }),
            ], footer: "Zoom works even on sites that switch it off."),
            SettingsSection(title: "History", rows: [
                .toggle("Group repeat visits",
                        get: { Settings.groupRepeatedVisits },
                        set: { [weak self] on in
                            Settings.groupRepeatedVisits = on
                            // History is a different mode, so the list isn't on
                            // screen — re-read now so it's already correct when
                            // it is opened.
                            self?.entries = self?.history?.recentEntries(grouping: on) ?? []
                        }),
            ]),
            // One section for the lot: the blocking level and the shields around
            // it are the same decision seen from different angles, and splitting
            // them meant scrolling past one to reach the other.
            SettingsSection(title: "Privacy", rows: [
                .blockingLevelPicker,
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
                .toggle("Block pop-ups and redirects",
                        get: { Settings.blockRedirectPages },
                        set: { Settings.blockRedirectPages = $0 }),
                .toggle("HTTPS-Only Mode",
                        get: { Settings.httpsOnly },
                        set: { Settings.httpsOnly = $0 }),
                .action("Content Blocking"),
                .action("Passwords"),
                // These two had handlers written for them and no row to reach
                // them from — a browser that can't be told to forget anything
                // is not one you can hand to somebody else for a minute.
                .destructive("Clear History"),
                .destructive("Clear Website Data"),
            ], footer: Settings.blockingLevel.summary
                     + "\n\nBlocking JavaScript is the strongest setting here, "
                     + "and the most likely to break a site."),
            SettingsSection(title: "Home", rows: [
                .action("Buttons"),
                .toggle("Favourites",
                        get: { Settings.showFavourites },
                        set: { Settings.showFavourites = $0 }),
                .toggle("Always show panel",
                        get: { Settings.startBoxShowsPanel },
                        set: { Settings.startBoxShowsPanel = $0 }),
                .slider("Swipe sensitivity",
                        get: { Settings.revealSwipeSensitivity },
                        set: { Settings.revealSwipeSensitivity = $0 }),
            ], footer: "Favourites: tap + to keep the page you're on, hold to "
                     + "remove.\n\nSwipe sensitivity sets how far you drag "
                     + "down a page to open Home."),
            SettingsSection(title: "Appearance", rows: [
                .toggle("Dark mode",
                        get: { Settings.darkMode },
                        set: { Settings.darkMode = $0 }),
                .action("App Icon"),
                .action("Wallpaper"),
            ], footer: "Dark mode off follows the system."),
            SettingsSection(title: "Media", rows: [
                // One switch for both halves: claiming the audio session and
                // telling the page it is still visible only work together, and
                // off by default because some video sites' terms disallow it.
                .toggle("Background audio",
                        get: { Settings.backgroundPlayback },
                        set: { on in
                            Settings.backgroundPlayback = on
                            NotificationCenter.default.post(name: .mediaSettingsChanged, object: nil)
                        }),
                .action("Video"),
            ], footer: "Background audio keeps sound going when you leave the "
                     + "app or lock the screen."),
            SettingsSection(title: "About", rows: [
                [.version],
                // Only shown once there is somewhere for them to go — see
                // `SupportInfo`, where both are still blank.
                SupportInfo.hasSupportURL ? [.action("Help")] : [],
                SupportInfo.hasContact ? [.action("Send Feedback"),
                                          .action("Report a Site Problem")] : [],
                [.action("Privacy Policy"), .action("Terms of Use"), .action("Licences")],
            ].flatMap { $0 },
                            footer: "Made with open-source software. No account, no analytics."),
        ]
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        switch mode {
        case .history, .downloads, .bookmarks: return 1
        case .settings:                        return settingsSections.count
        // The collection owns Tabs; the table is hidden and must claim nothing,
        // or it lays out settings rows behind the grid.
        case .tabs:                            return 0
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch mode {
        case .history, .downloads, .bookmarks, .tabs: return nil
        case .settings:                        return settingsSections[section].title
        }
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch mode {
        case .history, .downloads, .bookmarks, .tabs: return nil
        case .settings:                        return settingsSections[section].footer
        }
    }

    /// Tight, and tighter still for a section with no title.
    ///
    /// The default grouped spacing is drawn for a full screen; inside a 520pt
    /// card it wastes a row's worth of height between every group. A titled
    /// section gets just enough to separate the words from the rows above.
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard mode == .settings else { return .leastNormalMagnitude }
        return settingsSections[section].title == nil ? 8 : 30
    }

    /// A footer only earns space when it has something to say; the default
    /// reserves it either way.
    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard mode == .settings else { return .leastNormalMagnitude }
        return settingsSections[section].footer == nil ? 4 : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch mode {
        case .history:   return max(entries.count, 1)
        case .downloads: return max(downloads.count, 1)
        case .bookmarks: return max(bookmarks.count, 1)
        case .settings:  return settingsSections[section].rows.count
        case .tabs:      return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if mode == .downloads {
            return downloadCell(tableView, at: indexPath)
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = mode == .settings ? .secondarySystemFill : .clear
        cell.accessoryType = .none
        // Cells are shared across modes, so a switch left over from a Settings
        // row will ride a recycled cell into History unless it's cleared here.
        cell.accessoryView = nil
        cell.selectionStyle = .default
        let sel = UIView(); sel.backgroundColor = .quaternarySystemFill
        cell.selectedBackgroundView = sel

        if mode == .bookmarks {
            var cfg = UIListContentConfiguration.subtitleCell()
            if bookmarks.isEmpty {
                cfg.text = "No bookmarks yet"
                cfg.textProperties.color = .tertiaryLabel
                cell.selectionStyle = .none
            } else {
                let bookmark = bookmarks[indexPath.row]
                cfg.text = bookmark.title.isEmpty
                    ? (bookmark.url.host ?? bookmark.url.absoluteString) : bookmark.title
                cfg.secondaryText = bookmark.url.displayAddress
                cfg.secondaryTextProperties.color = .secondaryLabel
                cfg.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                // Filled, because everything in this list is kept — the outline
                // would be saying the opposite of what the row is.
                cfg.image = BookmarkIconView.filledImage(size: 18)
                cfg.imageProperties.tintColor = .tintColor
            }
            cfg.textProperties.numberOfLines = 1
            cfg.secondaryTextProperties.numberOfLines = 1
            cell.contentConfiguration = cfg
        } else if mode == .history {
            var cfg = UIListContentConfiguration.subtitleCell()
            if entries.isEmpty {
                cfg.text = "No history yet"
                cfg.textProperties.color = .tertiaryLabel
                cell.selectionStyle = .none
            } else {
                let e = entries[indexPath.row]
                cfg.text = e.title.isEmpty ? (e.url.host ?? e.url.absoluteString) : e.title
                let when = Self.relative.localizedString(for: e.date, relativeTo: Date())
                // The address, not just the host. On a site that keeps its name
                // in the title of every page, the host is the third copy of
                // something you already knew and the path is the only part that
                // says which page this was.
                let address = e.url.displayAddress
                // Visit counts come free with the visits table — worth showing.
                cfg.secondaryText = e.visitCount > 1
                    ? "\(address) · \(when) · \(e.visitCount) visits"
                    : "\(address) · \(when)"
                cfg.secondaryTextProperties.numberOfLines = 1
                cfg.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
                cfg.secondaryTextProperties.color = .secondaryLabel
                // A kept page wears the bookmark instead of the clock, so the
                // list says which of them you already saved without a second
                // column for it.
                let kept = BookmarkStore.shared.contains(e.url)
                cfg.image = kept ? BookmarkIconView.filledImage(size: 18)
                                 : UIImage(systemName: "clock")
                cfg.imageProperties.tintColor = kept ? .tintColor : .secondaryLabel
                // Tap-to-remove, matching the close button on a tab row. The
                // action captures the entry, not the index, so a recycled cell
                // can't delete the wrong row.
                cell.accessoryView = removeHistoryButton(for: e)
            }
            cfg.textProperties.numberOfLines = 1
            cfg.secondaryTextProperties.numberOfLines = 1
            cell.contentConfiguration = cfg
        } else {
            var cfg = UIListContentConfiguration.valueCell()
            cell.accessoryView = nil
            switch settingsSections[indexPath.section].rows[indexPath.row] {
            case .searchEnginePicker:
                cfg.text = "Search Engine"
                
                let currentEngine = Settings.searchEngine
                let menuButton = UIButton(type: .system)
                menuButton.setTitle(currentEngine.name, for: .normal)
                menuButton.showsMenuAsPrimaryAction = true
                
                let actions = SearchEngine.allCases.map { engine in
                    UIAction(title: engine.name, state: engine == currentEngine ? .on : .off) { _ in
                        Settings.searchEngine = engine
                        tableView.reloadRows(at: [indexPath], with: .none)
                    }
                }
                menuButton.menu = UIMenu(title: "", children: actions)
                menuButton.sizeToFit()
                
                cell.accessoryView = menuButton
                cell.selectionStyle = .none

            case .startPagePicker:
                cfg.text = "Opening Screen"

                let currentStart = Settings.startPage
                let startButton = UIButton(type: .system)
                startButton.setTitle(currentStart.name, for: .normal)
                startButton.showsMenuAsPrimaryAction = true
                startButton.menu = UIMenu(title: "", children: StartPage.allCases.map { page in
                    UIAction(title: page.name,
                             state: page == currentStart ? .on : .off) { _ in
                        Settings.startPage = page
                        tableView.reloadRows(at: [indexPath], with: .none)
                    }
                })
                startButton.sizeToFit()
                cell.accessoryView = startButton
                cell.selectionStyle = .none

            case .blockingLevelPicker:
                cfg.text = "Block Ads & Trackers"

                let currentLevel = Settings.blockingLevel
                let menuButton = UIButton(type: .system)
                menuButton.setTitle(currentLevel.name, for: .normal)
                menuButton.showsMenuAsPrimaryAction = true

                let actions = BlockingLevel.allCases.map { level in
                    UIAction(title: level.name, state: level == currentLevel ? .on : .off) { [weak self] _ in
                        Settings.blockingLevel = level
                        // Compiling a level for the first time takes a few
                        // seconds inside WebKit; the new rules apply from the
                        // next navigation either way.
                        NotificationCenter.default.post(name: .contentBlockingChanged, object: nil)
                        // The section footer describes the level, so the whole
                        // section is reloaded rather than the row alone.
                        self?.table.reloadSections(IndexSet(integer: indexPath.section),
                                                   with: .none)
                    }
                }
                menuButton.menu = UIMenu(title: "", children: actions)
                menuButton.sizeToFit()

                cell.accessoryView = menuButton
                cell.selectionStyle = .none

            case .toggle(let title, let get, let set):
                cfg.text = title
                let toggle = UISwitch()
                toggle.isOn = get()
                toggle.addAction(UIAction { _ in set(toggle.isOn) }, for: .valueChanged)
                cell.accessoryView = toggle
                cell.selectionStyle = .none

            case .slider(let title, let get, let set):
                cfg.text = title
                // Sized here rather than by constraints: an accessory view is
                // positioned by the cell from its frame, and a slider with no
                // intrinsic width would collapse.
                let slider = UISlider(frame: CGRect(x: 0, y: 0, width: 148, height: 28))
                slider.minimumValue = 0
                slider.maximumValue = 1
                slider.value = get()
                slider.addAction(UIAction { _ in set(slider.value) }, for: .valueChanged)
                cell.accessoryView = slider
                cell.selectionStyle = .none

            case .action(let title):
                cfg.text = title
                // Every one of these opens a screen, and until now none of them
                // said so — the About rows looked identical to Version, which
                // opens nothing. Applied to all of them rather than to About
                // alone: a chevron that appears on some rows that push and not
                // others teaches the wrong thing.
                cell.accessoryType = .disclosureIndicator

            case .destructive(let title):
                cfg.text = title
                cfg.textProperties.color = .systemRed

            case .version:
                cfg.text = "Version"
                cfg.secondaryText = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                    as? String ?? "1.0"
                cell.selectionStyle = .none
            }
            cell.contentConfiguration = cfg
        }
        return cell
    }

    /// The × on a history row — drops that one visit.
    private func removeHistoryButton(for entry: HistoryEntry) -> UIButton {
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        button.setImage(UIImage(systemName: "xmark"), for: .normal)
        button.tintColor = .secondaryLabel
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold), forImageIn: .normal)
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            history?.remove(entry)
            self.entries = history?.recentEntries(grouping: Settings.groupRepeatedVisits) ?? []
            self.table.reloadData()
        }, for: .touchUpInside)
        return button
    }

    /// One downloaded file. Empty state reuses the plain cell so the card doesn't
    /// look broken before anything has been downloaded.
    private func downloadCell(_ tableView: UITableView, at indexPath: IndexPath) -> UITableViewCell {
        guard !downloads.isEmpty else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
            cell.backgroundColor = .clear
            cell.accessoryView = nil
            cell.accessoryType = .none
                cell.selectionStyle = .none
            var cfg = UIListContentConfiguration.subtitleCell()
            cfg.text = downloadQuery.isEmpty ? "No downloads yet" : "No matches"
            cfg.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = cfg
            return cell
        }
        let cell = tableView.dequeueReusableCell(
            withIdentifier: DownloadCell.reuseID, for: indexPath) as! DownloadCell
        let item = downloads[indexPath.row]
        cell.configure(with: item)
        cell.onRetry = { [weak self] in
            DownloadManager.shared.retry(item)
            self?.downloadsChanged()
        }
        return cell
    }

    /// Route a destructive row through a confirmation, falling back to doing it
    /// only if nobody is listening — which never happens in the app, and is
    /// better than a row that silently does nothing if it ever did.
    private func confirm(_ title: String, _ consequence: String,
                         then act: @escaping () -> Void) {
        guard let onConfirmDestructive else { act(); return }
        onConfirmDestructive(title, consequence, act)
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if mode == .downloads {
            guard !downloads.isEmpty else { return }
            let item = downloads[indexPath.row]
            switch item.state {
            case .completed:   onOpenDownload?(item)
            case .failed:      DownloadManager.shared.retry(item); downloadsChanged()
            case .downloading: break
            }
        } else if mode == .history {
            guard !entries.isEmpty else { return }
            onOpenURL?(entries[indexPath.row].url)
        } else if mode == .bookmarks {
            guard !bookmarks.isEmpty else { return }
            onOpenURL?(bookmarks[indexPath.row].url)
        } else {
            switch settingsSections[indexPath.section].rows[indexPath.row] {
            case .destructive(let title):
                switch title {
                case "Clear History":
                    confirm(title, "Every page you have visited, forgotten.") { [weak self] in
                        self?.history?.clear()
                        self?.entries = []
                        self?.table.reloadData()
                    }
                case "Clear Website Data":
                    confirm(title, "Cookies, caches and local storage for every site. "
                                 + "You will be signed out of everything.") { [weak self] in
                        self?.onClearWebsiteData?()
                    }
                case "Clear completed downloads":
                    DownloadManager.shared.clearCompleted()
                case "Close All Tabs":
                    onCloseAllTabs?()
                default:
                    // Was `onCloseAllTabs?()`. A default that closes every tab
                    // means any destructive row added later without a matching
                    // case here silently wipes the session instead of doing
                    // nothing — the worst possible way to be wrong.
                    break
                }
            case .action(let title):
                switch title {
                case "Downloads":       onShowDownloads?()
                case "Buttons":         onShowStartBoxButtons?()
                case "Content Filtering": onShowContentFiltering?()
                case "Media":           onShowMediaSettings?()
                case "Wallpaper":       onShowAppearance?()
                case "App Icon":        onShowAppIcon?()
                case "Passwords":       onShowPasswords?()
                case "Licences":        onShowLicences?()
                case "Help":            onOpenSupport?(.help)
                case "Send Feedback":   onOpenSupport?(.feedback)
                case "Report a Site Problem": onOpenSupport?(.siteProblem)
                case "Privacy Policy":  onShowLegal?(.privacy)
                case "Terms of Use":    onShowLegal?(.terms)
                default:                break
                }
            case .searchEnginePicker, .startPagePicker, .blockingLevelPicker,
                 .toggle, .slider, .version:
                break
            }
        }
    }

    func tableView(_ tableView: UITableView,
                   trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        if mode == .downloads {
            guard !downloads.isEmpty else { return nil }
            let item = downloads[indexPath.row]
            // Deleting a row deletes the file too — say so.
            let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                DownloadManager.shared.remove(item)
                self?.downloadsChanged()
                done(true)
            }
            guard item.state == .downloading else {
                return UISwipeActionsConfiguration(actions: [delete])
            }
            let cancel = UIContextualAction(style: .normal, title: "Cancel") { [weak self] _, _, done in
                DownloadManager.shared.cancel(item)
                self?.downloadsChanged()
                done(true)
            }
            cancel.backgroundColor = .systemOrange
            return UISwipeActionsConfiguration(actions: [delete, cancel])
        }

        if mode == .bookmarks {
            guard !bookmarks.isEmpty else { return nil }
            let bookmark = bookmarks[indexPath.row]
            let remove = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                BookmarkStore.shared.remove(bookmark)
                // The store's notification comes back round to
                // `bookmarksChanged`, but the row has to go now — the swipe is
                // already open and waiting on this closure.
                self?.bookmarks = BookmarkStore.shared.bookmarks
                self?.table.reloadData()
                done(true)
            }
            remove.image = UIImage(systemName: "bookmark.slash")
            return UISwipeActionsConfiguration(actions: [remove])
        }

        guard mode == .history, !entries.isEmpty else { return nil }
        let entry = entries[indexPath.row]
        // Delete drops this one visit; Forget drops the page and every visit to
        // it — the same two-level model Firefox offers.
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
            guard let self else { done(false); return }
            history?.remove(entry)
            self.entries = history?.recentEntries(grouping: Settings.groupRepeatedVisits) ?? []
            tableView.reloadData()
            done(true)
        }
        let forget = UIContextualAction(style: .destructive, title: "Forget") { [weak self] _, _, done in
            guard let self else { done(false); return }
            history?.forget(entry)
            self.entries = history?.recentEntries(grouping: Settings.groupRepeatedVisits) ?? []
            tableView.reloadData()
            done(true)
        }
        forget.backgroundColor = .systemPurple
        return UISwipeActionsConfiguration(actions: [delete, forget])
    }

    /// Swipe a history row the other way to keep the page.
    ///
    /// The second half of bookmarking, and the half that's easy to miss: most
    /// pages worth keeping are ones you didn't know you'd want until later —
    /// and by then you are looking for them in History, not sitting on them.
    func tableView(_ tableView: UITableView,
                   leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
    -> UISwipeActionsConfiguration? {
        guard mode == .history, !entries.isEmpty else { return nil }
        let entry = entries[indexPath.row]
        let kept = BookmarkStore.shared.contains(entry.url)

        let keep = UIContextualAction(style: .normal,
                                      title: kept ? "Remove" : "Bookmark") { _, _, done in
            BookmarkStore.shared.toggle(url: entry.url, title: entry.title)
            UINotificationFeedbackGenerator().notificationOccurred(kept ? .warning : .success)
            tableView.reloadRows(at: [indexPath], with: .none)
            done(true)
        }
        keep.image = kept ? BookmarkIconView.filledImage() : BookmarkIconView.image()
        keep.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [keep])
    }
}

// MARK: - Downloads filter field

extension StartPanelView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

// MARK: - Download row

/// A download: file icon, name, status line, and either a progress bar (running)
/// or a retry button (failed). Finished rows are plain and tappable.
private final class DownloadCell: UITableViewCell {
    static let reuseID = "DownloadCell"

    var onRetry: (() -> Void)?

    private let icon = UIImageView()
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let retry = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        let sel = UIView(); sel.backgroundColor = .quaternarySystemFill
        selectedBackgroundView = sel

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration =
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        contentView.addSubview(icon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 15, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle    // keep the extension visible
        contentView.addSubview(nameLabel)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabel
        statusLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(statusLabel)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        contentView.addSubview(progress)

        retry.translatesAutoresizingMaskIntoConstraints = false
        retry.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retry.tintColor = .tintColor
        retry.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold), forImageIn: .normal)
        retry.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        retry.isHidden = true
        contentView.addSubview(retry)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),

            retry.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            retry.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            retry.widthAnchor.constraint(equalToConstant: 34),
            retry.heightAnchor.constraint(equalToConstant: 34),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: retry.leadingAnchor, constant: -8),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),

            statusLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),

            progress.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            progress.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: DownloadItem) {
        nameLabel.text = item.filename
        nameLabel.textColor = .label

        switch item.state {
        case .downloading:
            icon.image = UIImage(systemName: "arrow.down.circle")
            icon.tintColor = .tintColor
            progress.isHidden = false
            // An unknown total length has no meaningful bar, so show it empty
            // rather than pretending to be at 0%.
            progress.setProgress(Float(item.fractionCompleted), animated: false)
            retry.isHidden = true
            statusLabel.text = item.sizeDescription
            statusLabel.textColor = .secondaryLabel

        case .completed:
            icon.image = UIImage(systemName: "doc")
            icon.tintColor = .secondaryLabel
            progress.isHidden = true
            retry.isHidden = true
            statusLabel.text = "\(item.sizeDescription) · \(Self.stamp.string(from: item.date))"
            statusLabel.textColor = .secondaryLabel

        case .failed:
            icon.image = UIImage(systemName: "exclamationmark.triangle")
            icon.tintColor = .systemRed
            progress.isHidden = true
            retry.isHidden = false
            statusLabel.text = item.errorMessage ?? "Failed"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func retryTapped() {
        // Same turn as the page refresh button.
        retry.imageView?.spinOnce()
        onRetry?()
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()
}

// MARK: - Tab cell (works as a row or a grid card)

private final class TabItemCell: UICollectionViewCell {
    static let reuseID = "TabItemCell"

    var onClose: (() -> Void)?

    private let container = UIView()
    private let snapshotView = UIImageView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var gridConstraints: [NSLayoutConstraint] = []
    private var rowConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)

        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 16
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)

        // Page snapshot, grid mode only — fills the card behind the footer.
        snapshotView.translatesAutoresizingMaskIntoConstraints = false
        snapshotView.contentMode = .scaleAspectFill
        snapshotView.clipsToBounds = true
        snapshotView.backgroundColor = .quaternarySystemFill
        snapshotView.isHidden = true
        container.addSubview(snapshotView)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        container.addSubview(icon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(titleLabel)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .systemFont(ofSize: 12)
        urlLabel.textColor = .secondaryLabel
        urlLabel.lineBreakMode = .byTruncatingTail
        container.addSubview(urlLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        closeButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold), forImageIn: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        container.addSubview(closeButton)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            icon.widthAnchor.constraint(equalToConstant: 26),
            icon.heightAnchor.constraint(equalToConstant: 26),
            closeButton.widthAnchor.constraint(equalToConstant: 30),
            closeButton.heightAnchor.constraint(equalToConstant: 30),
        ])

        // Row: icon | title over url | close
        rowConstraints = [
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ]

        // Grid: page snapshot fills the card, footer (favicon + title) pinned to
        // the bottom, close button floating over the snapshot's top-right.
        gridConstraints = [
            snapshotView.topAnchor.constraint(equalTo: container.topAnchor),
            snapshotView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            snapshotView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            snapshotView.bottomAnchor.constraint(equalTo: icon.topAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            closeButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),

            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            icon.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            titleLabel.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with tab: Tab, isCurrent: Bool, grid: Bool) {
        NSLayoutConstraint.deactivate(grid ? rowConstraints : gridConstraints)
        NSLayoutConstraint.activate(grid ? gridConstraints : rowConstraints)

        titleLabel.numberOfLines = 1
        titleLabel.font = .systemFont(ofSize: grid ? 13 : 15, weight: .medium)
        container.backgroundColor = grid ? .quaternarySystemFill : .clear
        container.clipsToBounds = grid
        container.layer.borderWidth = (grid && isCurrent) ? 2 : 0
        container.layer.borderColor = UIColor.tintColor.cgColor

        // Snapshot only in grid mode; the url line only in row mode.
        snapshotView.isHidden = !grid
        urlLabel.isHidden = grid
        snapshotView.image = tab.snapshot
        // A close button floating over a snapshot needs its own backing to read.
        closeButton.backgroundColor = grid ? UIColor.systemBackground.withAlphaComponent(0.75) : .clear
        closeButton.layer.cornerRadius = grid ? 15 : 0

        titleLabel.text = tab.title.isEmpty ? (tab.url.host ?? tab.url.absoluteString) : tab.title
        titleLabel.textColor = isCurrent ? .tintColor : .label
        urlLabel.text = tab.url.host ?? tab.url.absoluteString

        if let favicon = tab.icon {
            icon.image = favicon
            icon.tintColor = nil
            icon.layer.cornerRadius = 6
            icon.clipsToBounds = true
        } else {
            icon.image = UIImage(systemName: "globe")
            icon.tintColor = isCurrent ? .tintColor : .secondaryLabel
            icon.layer.cornerRadius = 0
        }
    }

    @objc private func closeTapped() { onClose?() }
}

