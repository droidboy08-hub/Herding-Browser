import UIKit

/// The one screen shown on a genuinely fresh install.
///
/// Most browsers open onboarding to ask for something — to be made the default,
/// or for a sign-in. There is nothing here to ask for. This exists for a
/// different reason: TitleLess opens with a page and one small capsule, and
/// nothing on screen says that tapping it opens Home, that holding it opens the
/// menu, or that swiping it changes tabs. A browser with a toolbar teaches
/// itself. This one cannot.
///
/// So: one screen, five lines, and a button. Not a carousel — an app whose
/// whole argument is doing less should not open by making you page through
/// four slides about it.
final class WelcomeViewController: UIViewController {

    var onDismiss: (() -> Void)?

    private struct Gesture {
        let symbol: String
        let title: String
        let detail: String
    }

    private let gestures: [Gesture] = [
        Gesture(symbol: "capsule",
                title: "Tap the capsule",
                detail: "The pill at the bottom. Opens Home — the address field, tabs, history and settings."),
        Gesture(symbol: "hand.tap",
                title: "Hold it",
                detail: "Share, bookmark, print, desktop site and the rest."),
        Gesture(symbol: "arrow.left.arrow.right",
                title: "Swipe it sideways",
                detail: "Moves between your open tabs."),
        Gesture(symbol: "arrow.down",
                title: "Pull down a page",
                detail: "Reloads it."),
        Gesture(symbol: "arrow.uturn.backward",
                title: "Swipe from either edge",
                detail: "Back and forward, as in Safari."),
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let title = UILabel()
        title.text = "TitleLess"
        title.font = Self.rounded(34, .bold)
        title.textColor = .label

        let subtitle = UILabel()
        subtitle.text = "Almost no browser, and that is the point.\nHere is everything you need to know."
        subtitle.font = .systemFont(ofSize: 16)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        let rows = UIStackView(arrangedSubviews: gestures.map(row(for:)))
        rows.axis = .vertical
        rows.spacing = 22

        let start = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Start Browsing"
        config.cornerStyle = .large
        config.buttonSize = .large
        start.configuration = config
        start.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Recorded before dismissing, so a crash between the two does not
            // mean seeing this again.
            Settings.hasSeenWelcome = true
            dismiss(animated: true) { self.onDismiss?() }
        }, for: .touchUpInside)

        let content = UIStackView(arrangedSubviews: [title, subtitle, rows])
        content.axis = .vertical
        content.spacing = 28
        content.setCustomSpacing(12, after: title)
        content.translatesAutoresizingMaskIntoConstraints = false

        // Scrollable, because five rows plus a heading do not fit a small phone
        // at the larger accessibility text sizes.
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = false
        scroll.addSubview(content)
        view.addSubview(scroll)

        start.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(start)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: guide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: start.topAnchor, constant: -20),

            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 44),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -28),

            start.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 28),
            start.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -28),
            start.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -20),
        ])
    }

    private func row(for gesture: Gesture) -> UIView {
        let icon = UIImageView(image: UIImage(systemName: gesture.symbol))
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let title = UILabel()
        title.text = gesture.title
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = .label

        let detail = UILabel()
        detail.text = gesture.detail
        detail.font = .systemFont(ofSize: 14)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0

        let text = UIStackView(arrangedSubviews: [title, detail])
        text.axis = .vertical
        text.spacing = 2

        let row = UIStackView(arrangedSubviews: [icon, text])
        row.axis = .horizontal
        row.spacing = 14
        row.alignment = .top
        return row
    }

    private static func rounded(_ size: CGFloat, _ weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}
