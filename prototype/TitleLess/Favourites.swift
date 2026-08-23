import UIKit

/// A site kept on the start box.
struct Favourite: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var url: URL

    /// A colour derived from the host, so a site without an icon is still
    /// recognisable by its tile rather than being one grey circle among five.
    var monogramColour: UIColor {
        var hash: UInt64 = 5381
        for byte in (url.host ?? title).utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return UIColor(hue: CGFloat(hash % 360) / 360,
                       saturation: 0.55, brightness: 0.62, alpha: 1)
    }

    /// The letter drawn when there is no icon to draw.
    var initial: String {
        let source = (url.host ?? title).replacingOccurrences(of: "www.", with: "")
        return String(source.prefix(1)).uppercased()
    }
}

/// The favourites, and the icons for them.
///
/// Capped rather than unbounded, and deliberately. These sit in a single row
/// under the search field: a row that scrolls is a row you have to look through,
/// which is the thing a favourite is supposed to save you from. Six is what fits
/// at a size you can hit without aiming.
@MainActor
final class FavouritesStore {

    static let shared = FavouritesStore()

    static let didChangeNotification = Notification.Name("FavouritesStore.didChange")

    /// The number of slots. The row is this many plus the add button, and the
    /// two together have to fit the card's width at a size worth tapping — which
    /// is what sets the number, not a round figure.
    static let capacity = 5

    private(set) var favourites: [Favourite] = []

    private let fileURL: URL
    private let iconDirectory: URL

    /// Icons come from the site itself, over a connection that carries no
    /// cookies and leaves nothing in a shared cache — the same rule the rest of
    /// the app follows for anything fetched outside a page.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        fileURL = support.appendingPathComponent("favourites.json")
        iconDirectory = support.appendingPathComponent("FavouriteIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: iconDirectory,
                                                 withIntermediateDirectories: true)
        load()
    }

    var isFull: Bool { favourites.count >= Self.capacity }

    func contains(_ url: URL) -> Bool {
        favourites.contains { $0.url.host == url.host }
    }

    /// - Parameter iconHints: icon addresses harvested from the page, when it
    ///   is the page being added.
    @discardableResult
    func add(url: URL, title: String, iconHints: [URL] = []) -> Bool {
        guard url.isWebPage, !isFull, !contains(url) else { return false }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let favourite = Favourite(id: UUID(),
                                  title: name.isEmpty ? (url.host ?? url.absoluteString) : name,
                                  url: url)
        favourites.append(favourite)
        save()
        Task { await refreshIcon(for: favourite, hints: iconHints) }
        return true
    }

    func remove(_ favourite: Favourite) {
        favourites.removeAll { $0.id == favourite.id }
        try? FileManager.default.removeItem(at: iconURL(for: favourite))
        save()
    }

    /// For Shred App Data. The icons go too — each one was fetched from a site
    /// the user visited, so the folder is a list of where they have been.
    func removeAll() {
        favourites.removeAll()
        try? FileManager.default.removeItem(at: iconDirectory)
        try? FileManager.default.createDirectory(at: iconDirectory,
                                                 withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
        save()
    }

    func icon(for favourite: Favourite) -> UIImage? {
        UIImage(contentsOfFile: iconURL(for: favourite).path)
    }

    private func iconURL(for favourite: Favourite) -> URL {
        iconDirectory.appendingPathComponent("\(favourite.id.uuidString).png")
    }

    /// Ask the site for the best icon it has.
    ///
    /// Same order of preference a browser's own favicon service uses: the large
    /// icons a site publishes for home-screen shortcuts first, its web-app
    /// manifest next, and the 16-pixel `favicon.ico` only as a last resort. A
    /// tile drawn from a 16-pixel source looks like a 16-pixel source, which is
    /// what made these look cheap.
    ///
    /// Everything is fetched from the site itself. There are public services
    /// that will hand over any site's icon from one endpoint, and they are far
    /// easier — but asking one of them means telling a third party which sites
    /// this person keeps, which is the opposite of what this browser is for.
    ///
    /// - Parameter hints: icon URLs read from the page's own markup, when the
    ///   page is open. A site that names its icon is more reliable than any
    ///   guess at a path, and it is the only way to find one that isn't at a
    ///   conventional address.
    func refreshIcon(for favourite: Favourite, hints: [URL] = []) async {
        guard let host = favourite.url.host else { return }

        var candidates = hints
        candidates.append(contentsOf: [
            "apple-touch-icon-180x180.png",
            "apple-touch-icon.png",
            "apple-touch-icon-precomposed.png",
            "favicon-192x192.png",
            "favicon-96x96.png",
            "favicon.png",
            "favicon.ico",
        ].compactMap { URL(string: "https://\(host)/\($0)") })

        var best: UIImage?
        for candidate in candidates {
            guard let (data, response) = try? await session.data(from: candidate),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data) else { continue }
            // Keep the largest thing found, and stop as soon as something is
            // big enough to draw at tile size on a 3x screen.
            if image.size.width > (best?.size.width ?? 0) { best = image }
            if image.size.width >= 120 { break }
        }

        // Below this a monogram genuinely looks better than the real icon.
        guard let best, best.size.width >= 48 else { return }
        let rendered = best.scaled(toFit: CGSize(width: 180, height: 180))
        guard let png = rendered.pngData() else { return }
        try? png.write(to: iconURL(for: favourite), options: .atomic)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([Favourite].self, from: data) else { return }
        favourites = stored
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favourites) {
            try? data.write(to: fileURL, options: .atomic)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}

/// The row of favourites under the search field.
///
/// Sized to the card rather than scrolling: every slot is visible at once, and
/// the add button sits at the end of the row so the shape of the row tells you
/// how many are left.
final class FavouritesBar: UIView {

    var onOpen: ((URL) -> Void)?
    var onAdd: (() -> Void)?
    var onRemove: ((Favourite) -> Void)?

    private let stack = UIStackView()
    private static let itemSize: CGFloat = 38
    /// The height the row needs when it is shown. Owned by the caller, which
    /// collapses it to zero when the setting is off.
    static var rowHeight: CGFloat { itemSize }

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .horizontal
        stack.alignment = .center
        // Fixed gaps with the row left-aligned, rather than space distributed
        // between however many tiles there are. With `.equalSpacing` the gap
        // changed every time a favourite was added, and the placeholder slots
        // that kept the row's shape ate the width the spacing needed — leaving
        // the add button jammed against the last tile.
        stack.distribution = .fill
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for favourite in FavouritesStore.shared.favourites {
            stack.addArrangedSubview(makeTile(for: favourite))
        }
        if !FavouritesStore.shared.isFull {
            stack.addArrangedSubview(makeAddButton())
        }
        // One flexible tail, so the tiles stay left-aligned and evenly spaced
        // whether there is one of them or five.
        stack.addArrangedSubview(makeSpacer())
    }

    private func makeTile(for favourite: Favourite) -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .quaternarySystemFill
        button.layer.cornerRadius = Self.itemSize / 2
        button.clipsToBounds = true
        button.accessibilityLabel = favourite.title

        if let icon = FavouritesStore.shared.icon(for: favourite) {
            button.setImage(icon.withRenderingMode(.alwaysOriginal), for: .normal)
            button.imageView?.contentMode = .scaleAspectFill
            button.contentVerticalAlignment = .fill
            button.contentHorizontalAlignment = .fill
        } else {
            // A monogram on a colour taken from the host, so two sites without
            // icons still look like two different sites.
            button.backgroundColor = favourite.monogramColour
            button.setTitle(favourite.initial, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
            button.setTitleColor(.white, for: .normal)
        }

        button.addAction(UIAction { [weak self] _ in
            self?.onOpen?(favourite.url)
        }, for: .primaryActionTriggered)

        // Removing is a long press, not an X on every tile: six delete buttons
        // in a row is a row of delete buttons, not a row of favourites.
        button.menu = UIMenu(children: [
            UIAction(title: "Remove",
                     image: UIImage(systemName: "trash"),
                     attributes: .destructive) { [weak self] _ in
                self?.onRemove?(favourite)
            }
        ])
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.itemSize),
            Self.itemHeight(button),
        ])
        return button
    }

    /// The tile's height, at a priority the collapsed row can beat.
    ///
    /// Required, this fights the caller: the row is hidden by pinning the bar's
    /// height to zero, and the stack inside is pinned to its top and bottom, so
    /// a required 38 inside a 0-high bar is unsatisfiable and UIKit breaks one
    /// of them for us. Which one it picks is not ours to decide, and it logged
    /// every time favourites were switched off. At 999 the tile simply yields
    /// while the row is collapsed and is exact everywhere else.
    private static func itemHeight(_ view: UIView) -> NSLayoutConstraint {
        let constraint = view.heightAnchor.constraint(equalToConstant: itemSize)
        constraint.priority = .init(999)
        return constraint
    }

    private func makeAddButton() -> UIView {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setImage(UIImage(systemName: "plus"), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = "Add favourite"
        // Dashed, so an empty slot reads as somewhere to put something rather
        // than as a button that does nothing.
        button.backgroundColor = .clear
        button.layer.cornerRadius = Self.itemSize / 2
        let border = CAShapeLayer()
        border.path = UIBezierPath(ovalIn: CGRect(x: 0, y: 0,
                                                  width: Self.itemSize,
                                                  height: Self.itemSize)).cgPath
        border.strokeColor = UIColor.separator.cgColor
        border.fillColor = UIColor.clear.cgColor
        border.lineDashPattern = [4, 3]
        border.lineWidth = 1.5
        button.layer.addSublayer(border)
        button.addAction(UIAction { [weak self] _ in self?.onAdd?() },
                         for: .primaryActionTriggered)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: Self.itemSize),
            Self.itemHeight(button),
        ])
        return button
    }

    /// Takes whatever width is left over, and gives it up first.
    private func makeSpacer() -> UIView {
        let spacer = UIView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }
}


private extension UIImage {
    /// Downscale to fit, never up — an icon stretched past its own resolution
    /// is the blur this was meant to avoid.
    func scaled(toFit limit: CGSize) -> UIImage {
        let ratio = min(limit.width / size.width, limit.height / size.height, 1)
        guard ratio < 1 else { return self }
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
