import UIKit

/// A page the user kept.
struct Bookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: URL
    var added: Date
}

/// The bookmark list, stored as one JSON file beside the profile's other state.
///
/// Not in SQLite, and deliberately: bookmarks are read and written whole, a few
/// hundred at the very most, and the database exists for history — which is
/// queried, ranked and expired. A file is the honest shape for this.
@MainActor
final class BookmarkStore {

    static let shared = BookmarkStore()

    static let didChangeNotification = Notification.Name("BookmarkStore.didChange")

    private(set) var bookmarks: [Bookmark] = []
    private let fileURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("bookmarks.json")
        load()
    }

    func contains(_ url: URL) -> Bool {
        bookmarks.contains { $0.url == url }
    }

    /// Add a page, or remove it if it's already kept — the star behaviour every
    /// browser has, so one menu item covers both directions.
    @discardableResult
    func toggle(url: URL, title: String) -> Bool {
        if let existing = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: existing)
            save()
            return false
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.insert(Bookmark(id: UUID(),
                                  title: name.isEmpty ? (url.host ?? url.absoluteString) : name,
                                  url: url,
                                  added: Date()),
                         at: 0)
        save()
        return true
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        bookmarks = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// The bookmark list. Tap to open, swipe to delete.
final class BookmarksViewController: UIViewController {

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    private let onOpen: (URL) -> Void

    init(onOpen: @escaping (URL) -> Void) {
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bookmarks"
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

extension BookmarksViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(BookmarkStore.shared.bookmarks.count, 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var cfg = UIListContentConfiguration.subtitleCell()
        let bookmarks = BookmarkStore.shared.bookmarks

        guard !bookmarks.isEmpty else {
            cfg.text = "No bookmarks yet"
            cfg.textProperties.color = .tertiaryLabel
            cell.contentConfiguration = cfg
            cell.selectionStyle = .none
            return cell
        }
        let bookmark = bookmarks[indexPath.row]
        cfg.text = bookmark.title
        cfg.secondaryText = bookmark.url.host ?? bookmark.url.absoluteString
        cfg.secondaryTextProperties.color = .secondaryLabel
        cfg.image = BookmarkIconView.filledImage(size: 18)
        cfg.imageProperties.tintColor = .secondaryLabel
        cell.contentConfiguration = cfg
        cell.selectionStyle = .default
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let bookmarks = BookmarkStore.shared.bookmarks
        guard indexPath.row < bookmarks.count else { return }
        let url = bookmarks[indexPath.row].url
        dismiss(animated: true) { [onOpen] in onOpen(url) }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < BookmarkStore.shared.bookmarks.count
    }

    func tableView(_ tableView: UITableView,
                   commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete,
              indexPath.row < BookmarkStore.shared.bookmarks.count else { return }
        BookmarkStore.shared.remove(BookmarkStore.shared.bookmarks[indexPath.row])
        tableView.reloadData()
    }
}
