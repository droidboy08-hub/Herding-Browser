import PhotosUI
import UIKit

/// Wallpaper picking: a still, a short clip, or nothing.
///
/// Uses `PHPickerViewController`, which runs out of process — the user picks in
/// a view the app cannot see, and only the chosen item is handed over. That is
/// why there is no photo-library permission prompt here, and why there shouldn't
/// be: a browser has no business being able to read the library.
final class AppearanceSettingsViewController: UIViewController {

    private let table = UITableView(frame: .zero, style: .insetGrouped)
    /// The built-in gradients, laid out as a grid in the table's header rather
    /// than as rows: a wallpaper is chosen by looking at it, and a list of names
    /// with tiny thumbnails makes you read what you should be able to see.
    private lazy var presetPicker = WallpaperPresetPicker { [weak self] picked in
        picked.apply()
        // Only the table: the picker repaints its own selection, and reaching
        // back into it from the closure it was built with is a circular
        // reference the compiler is right to refuse.
        self?.table.reloadData()
    }

    private enum Row: Int, CaseIterable {
        case photo, video

        var title: String {
            switch self {
            case .photo: return "Choose Photo"
            case .video: return "Choose Live Video"
            }
        }

        var kind: WallpaperKind {
            switch self {
            case .photo: return .photo
            case .video: return .video
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // A table header sizes itself from a frame, not from constraints.
        presetPicker.frame = CGRect(x: 0, y: 0, width: table.bounds.width,
                                    height: WallpaperPresetPicker.height)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Background"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        table.tableHeaderView = presetPicker
        presetPicker.frame = CGRect(x: 0, y: 0, width: view.bounds.width,
                                    height: WallpaperPresetPicker.height)
        table.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    private func present(picker filter: PHPickerFilter) {
        var config = PHPickerConfiguration()
        config.filter = filter
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func report(_ message: String) {
        let alert = UIAlertController(title: "Couldn't set that background",
                                      message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - Table

extension AppearanceSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "A moving background costs battery while it is on screen, which is why it "
        + "stops the moment you leave the start box."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let row = Row.allCases[indexPath.row]
        var cfg = UIListContentConfiguration.cell()
        cfg.text = row.title
        cell.contentConfiguration = cfg
        // The tick marks what is in use now, so the list doubles as the answer
        // to "what have I got set?"
        cell.accessoryType = WallpaperStore.kind == row.kind ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row.allCases[indexPath.row] {
        case .photo: present(picker: .images)
        case .video: present(picker: .videos)
        }
    }
}

// MARK: - PHPickerViewControllerDelegate

extension AppearanceSettingsViewController: PHPickerViewControllerDelegate {

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }

        if provider.canLoadObject(ofClass: UIImage.self) {
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
                Task { @MainActor in
                    guard let image = object as? UIImage else {
                        self?.report(error?.localizedDescription ?? "That image couldn't be read.")
                        return
                    }
                    do {
                        try WallpaperStore.install(photo: image)
                        self?.table.reloadData()
                    } catch {
                        self?.report(error.localizedDescription)
                    }
                }
            }
            return
        }

        // Video arrives as a file the system will delete as soon as this
        // callback returns, so it has to be copied inside the handler rather
        // than after it.
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) {
            [weak self] url, error in
            guard let url else {
                Task { @MainActor in
                    self?.report(error?.localizedDescription ?? "That video couldn't be read.")
                }
                return
            }
            // Copy on this thread, while the temporary file still exists.
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            do {
                try FileManager.default.copyItem(at: url, to: scratch)
            } catch {
                Task { @MainActor in self?.report(error.localizedDescription) }
                return
            }
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: scratch) }
                do {
                    try WallpaperStore.install(videoAt: scratch)
                    self?.table.reloadData()
                } catch {
                    self?.report(error.localizedDescription)
                }
            }
        }
    }
}


/// Something the grid can offer.
///
/// Main-actor, because reading and setting the wallpaper is: the store posts
/// notifications that redraw the start box.
@MainActor
enum PickableWallpaper: Equatable {
    /// No wallpaper, shown as a swatch of the plain background so that "none"
    /// is chosen by looking at it like everything else here.
    case system
    case picture(BuiltInWallpaper)
    case gradient(WallpaperPreset)

    var name: String {
        switch self {
        case .system:               return WallpaperPreset.system.name
        case .picture(let picture): return picture.name
        case .gradient(let preset): return preset.name
        }
    }

    /// Whether this is the one currently behind the start box.
    var isInUse: Bool {
        switch self {
        case .system:               return WallpaperStore.kind == .none
        case .picture(let picture): return WallpaperStore.builtIn?.id == picture.id
        case .gradient(let preset): return WallpaperStore.preset?.id == preset.id
        }
    }

    func apply() {
        switch self {
        case .system:               WallpaperStore.clear()
        case .picture(let picture): WallpaperStore.install(builtIn: picture)
        case .gradient(let preset): WallpaperStore.install(preset: preset)
        }
    }

    func thumbnail(size: CGSize) -> UIImage? {
        switch self {
        case .system:
            return WallpaperPreset.system.thumbnail(size: size)
        case .gradient(let preset):
            return preset.thumbnail(size: size)
        case .picture(let picture):
            guard let url = picture.url else { return nil }
            // Decoded to swatch size rather than to the picture's own — see
            // `WallpaperImageLoader`.
            return WallpaperImageLoader.image(
                at: url, maxPixel: max(size.width, size.height) * UIScreen.main.scale)
        }
    }
}

/// The grid of wallpapers that ship with the app.
///
/// Its own view rather than a row in the table: swatches want to be side by side
/// at the shape of a screen, which a table row is bad at, and the choice is a
/// visual one anyway.
///
/// Two rows, not one: the pictures and the gradients are different kinds of
/// thing, and a single scroller long enough to hold both is one you have to
/// drag through to find out what is in it. The pictures row is left out
/// entirely when none ship.
final class WallpaperPresetPicker: UIView {

    private static let spacing: CGFloat = 14

    /// Photo tiles are cut to roughly the proportions of a phone, so a picture
    /// fills one without losing its top and bottom. Gradients don't need it —
    /// a ramp looks like itself at any shape — and a row of tall tiles for them
    /// would cost half the screen to say nothing extra.
    private static let photoSwatch = CGSize(width: 94, height: 186)
    private static let gradientSwatch = CGSize(width: 92, height: 106)
    /// Swatch, the gap under it, and the name.
    private static let captionHeight: CGFloat = 28
    /// The heading above each row.
    private static let headingHeight: CGFloat = 28

    private static func rowHeight(for swatch: CGSize) -> CGFloat {
        headingHeight + swatch.height + captionHeight
    }

    static var height: CGFloat {
        var total = spacing + rowHeight(for: gradientSwatch) + spacing
        if !BuiltInWallpaper.all.isEmpty {
            total += rowHeight(for: photoSwatch) + spacing
        }
        return total
    }

    private let stack = UIStackView()
    private var rows: [WallpaperRow] = []
    private let onPick: (PickableWallpaper) -> Void

    init(onPick: @escaping (PickableWallpaper) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)

        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.spacing),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        if !BuiltInWallpaper.all.isEmpty {
            addRow(title: "PHOTOS",
                   items: BuiltInWallpaper.all.map(PickableWallpaper.picture),
                   swatch: Self.photoSwatch)
        }
        addRow(title: "GRADIENTS",
               items: [.system] + WallpaperPreset.all.map(PickableWallpaper.gradient),
               swatch: Self.gradientSwatch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addRow(title: String, items: [PickableWallpaper], swatch: CGSize) {
        let row = WallpaperRow(title: title, items: items, swatch: swatch) { [weak self] picked in
            self?.onPick(picked)
            // Every row: choosing a picture has to clear the ring off whatever
            // gradient was selected before it, and the other way round.
            self?.reload()
        }
        row.heightAnchor.constraint(equalToConstant: Self.rowHeight(for: swatch)).isActive = true
        stack.addArrangedSubview(row)
        rows.append(row)
    }

    func reload() { rows.forEach { $0.reload() } }
}

/// A heading and a horizontal strip of swatches.
private final class WallpaperRow: UIView {

    private let items: [PickableWallpaper]
    private let swatchSize: CGSize
    private let onPick: (PickableWallpaper) -> Void
    private let title = UILabel()
    private lazy var collection: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: swatchSize.width, height: swatchSize.height + 26)
        layout.minimumLineSpacing = 12
        layout.sectionInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.register(SwatchCell.self, forCellWithReuseIdentifier: SwatchCell.reuseID)
        return view
    }()

    init(title text: String, items: [PickableWallpaper], swatch: CGSize,
         onPick: @escaping (PickableWallpaper) -> Void) {
        self.items = items
        self.swatchSize = swatch
        self.onPick = onPick
        super.init(frame: .zero)

        title.text = text
        title.font = .preferredFont(forTextStyle: .footnote)
        title.textColor = .secondaryLabel
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        collection.dataSource = self
        collection.delegate = self
        collection.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collection)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),

            collection.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 10),
            collection.leadingAnchor.constraint(equalTo: leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: trailingAnchor),
            collection.heightAnchor.constraint(equalToConstant: swatch.height + 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() { collection.reloadData() }
}

extension WallpaperRow: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SwatchCell.reuseID, for: indexPath) as! SwatchCell
        let item = items[indexPath.item]
        cell.configure(with: item, size: swatchSize, selected: item.isInUse)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        UISelectionFeedbackGenerator().selectionChanged()
        onPick(items[indexPath.item])
    }
}

/// One swatch: the wallpaper, its name, and a ring when it's the one in use.
private final class SwatchCell: UICollectionViewCell {

    static let reuseID = "swatch"

    private let swatch = UIImageView()
    private let label = UILabel()
    /// Set per row: a photo tile is the shape of a phone, a gradient tile isn't.
    private var swatchHeight: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Drawn at the phone's aspect ratio, so the swatch is a small picture of
        // what the screen will look like rather than an unrelated square.
        swatch.contentMode = .scaleAspectFill
        swatch.clipsToBounds = true
        swatch.backgroundColor = .tertiarySystemFill
        swatch.layer.cornerRadius = 14
        swatch.layer.cornerCurve = .continuous
        swatch.layer.borderWidth = 3
        swatch.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(swatch)

        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)

        swatchHeight = swatch.heightAnchor.constraint(equalToConstant: 106)
        NSLayoutConstraint.activate([
            swatch.topAnchor.constraint(equalTo: contentView.topAnchor),
            swatch.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            swatch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            swatchHeight,

            label.topAnchor.constraint(equalTo: swatch.bottomAnchor, constant: 6),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with item: PickableWallpaper, size: CGSize, selected: Bool) {
        swatchHeight.constant = size.height
        swatch.image = item.thumbnail(size: size)
        label.text = item.name
        // Always fill. Fitting a 1320×2868 picture into a squat tile pillarboxes
        // it into a sliver between two grey bars — the picture is technically
        // all there and you can see none of it. The photo tiles are cut to the
        // shape of a phone instead, so filling *is* showing it whole, and the
        // swatch is a small picture of what the screen will look like.
        swatch.contentMode = .scaleAspectFill
        label.textColor = selected ? .tintColor : .secondaryLabel
        swatch.layer.borderColor = selected ? UIColor.tintColor.cgColor
                                            : UIColor.clear.cgColor
    }
}
