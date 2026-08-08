import UIKit

/// Pick the icon the app wears on the home screen.
///
/// Both icons are Icon Composer bundles, declared to the asset catalogue rather
/// than by hand in Info.plist: the primary through
/// `ASSETCATALOG_COMPILER_APPICON_NAME`, the alternate through
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`. That is what lets an
/// alternate be a `.icon` at all — the old loose-PNG route can only carry a flat
/// image, and would throw away the layering, the dark and tinted appearances,
/// and the specular pass that make the icon match the platform.
///
/// The rows draw loose preview PNGs rather than the icons themselves, because
/// an app cannot load its own icon. Icon Composer icons compile to `Icon Image`
/// renditions, and `UIImage(named: "AppIcon")` does not merely fail on those —
/// it raises inside UIKit and takes the app down. The previews are flattened
/// from the same `.icon` bundles by `tools/build-icon-previews.swift`, so they
/// stay in step with the artwork by construction rather than by memory.
final class AppIconViewController: UIViewController {

    /// `nil` is the icon the app shipped with; that is also what
    /// `setAlternateIconName` takes to mean "put it back".
    private struct Choice {
        let name: String?
        let title: String
        let preview: String        // the asset to draw in the row
    }

    private let choices: [Choice] = [
        Choice(name: nil, title: "Default", preview: "AppIcon-Preview"),
        Choice(name: "AppIcon-Atlas", title: "Atlas", preview: "AppIcon-Atlas-Preview"),
    ]

    private let table = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "App Icon"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 76
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

    /// The rounded-square treatment iOS puts on every home-screen icon, applied
    /// here so a row looks like the thing it is choosing.
    ///
    /// Takes a *preview* name, never an icon name — see the note on the class.
    static func preview(named name: String, side: CGFloat = 56) -> UIImage? {
        guard let image = UIImage(named: name) else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            UIBezierPath(roundedRect: rect, cornerRadius: side * 0.225).addClip()
            image.draw(in: rect)
        }
    }

    /// The preview asset for whichever icon the app is wearing right now.
    ///
    /// `alternateIconName` is `nil` while the shipped icon is in use; every
    /// preview is its icon's name with `-Preview` on the end, so a new icon
    /// needs no entry here.
    static var currentIconPreviewName: String {
        (UIApplication.shared.alternateIconName ?? "AppIcon") + "-Preview"
    }
}

extension AppIconViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        choices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let choice = choices[indexPath.row]
        var cfg = UIListContentConfiguration.cell()
        cfg.text = choice.title
        cfg.image = Self.preview(named: choice.preview)
        cfg.imageProperties.maximumSize = CGSize(width: 56, height: 56)
        cfg.imageProperties.cornerRadius = 12
        cell.contentConfiguration = cfg
        cell.accessoryType =
            UIApplication.shared.alternateIconName == choice.name ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let choice = choices[indexPath.row]
        guard UIApplication.shared.alternateIconName != choice.name else { return }

        UIApplication.shared.setAlternateIconName(choice.name) { [weak self] error in
            Task { @MainActor in
                if let error {
                    let alert = UIAlertController(
                        title: "Couldn't change the icon",
                        message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self?.present(alert, animated: true)
                }
                // The settings row behind this screen draws whichever icon is
                // set, so it is now out of date.
                NotificationCenter.default.post(name: .appearanceChanged, object: nil)
                self?.table.reloadData()
            }
        }
    }
}
