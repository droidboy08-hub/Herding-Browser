import UIKit

/// Plain-text editor for the user's own filter rules.
///
/// The rules use the same syntax as the bundled lists, because they go into the
/// same engine — `||ads.example.com^` to block a host, `example.com##.promo` to
/// hide an element, `@@||example.com/needed.js` to put one back. They are
/// appended last, so a rule written here beats a rule from a list.
///
/// Deliberately a text box rather than a builder UI: anyone who wants custom
/// filters at all already knows the syntax, and a builder would cover a fraction
/// of what one line of it can say.
final class CustomFiltersViewController: UIViewController {

    private let textView = UITextView()
    private let initialRules: String
    private let onSave: (String) -> Void

    init(rules: String, onSave: @escaping (String) -> Void) {
        initialRules = rules
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Custom Filters"

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done, primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                onSave(textView.text)
                dismiss(animated: true)
            })

        // Monospaced, and with every text "helper" off: these are rules, and an
        // autocapitalised or smart-quoted rule is a broken rule.
        textView.text = initialRules
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.keyboardType = .asciiCapable
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        let hint = UILabel()
        hint.text = "One rule per line. ||host^ blocks, ##.selector hides, "
                  + "@@ makes an exception."
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -20),

            textView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }
}
