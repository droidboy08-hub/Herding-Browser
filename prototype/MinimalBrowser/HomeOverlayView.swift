import UIKit

/// The start page: a frosted-glass "window" floating in the middle of the frame
/// with a URL/search field and, below it, a scrollable list of open tabs (each
/// row has a close button). The only chrome in the app.
final class HomeOverlayView: UIView {

    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onHistory: (() -> Void)?
    var onSettings: (() -> Void)?

    private let historyButton = UIButton(type: .system)
    private let settingsButton = UIButton(type: .system)

    private let solidBackdrop = UIView()
    private let blurBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    private let shadowHost = UIView()
    private let fieldContainer = UIView()
    private let field = UITextField()
    private let listContainer = UIView()
    private let tabList = UITableView(frame: .zero, style: .plain)
    private let stack = UIStackView()
    let panel = StartPanelView()   // second glass card (history / settings)

    private var tabs: [Tab] = []
    private var currentTabID: UUID?

    private var listHeight: NSLayoutConstraint!   // adaptive: grows with tab count, capped
    private var cardBottom: NSLayoutConstraint!   // keeps the card above the keyboard
    private var keyboardHeight: CGFloat = 0

    private let rowHeight: CGFloat = 60
    // Fixed chrome above the list (title + field + paddings) used to cap the list.
    private let chromeAboveList: CGFloat = 20 + 34 + 14 + 52 + 16 + 22

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        backgroundColor = .clear

        solidBackdrop.translatesAutoresizingMaskIntoConstraints = false
        solidBackdrop.backgroundColor = .systemBackground
        addSubview(solidBackdrop)

        blurBackdrop.translatesAutoresizingMaskIntoConstraints = false
        blurBackdrop.alpha = 0
        addSubview(blurBackdrop)

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

        // Start box + optional panel live in a centered vertical stack, so opening
        // the panel pushes the start box up and the pair stays centered.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        addSubview(stack)
        stack.addArrangedSubview(card)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        panel.heightAnchor.constraint(equalToConstant: 340).isActive = true   // fixed; scrolls inside
        panel.onClose = { [weak self] in self?.hidePanel() }
        stack.addArrangedSubview(panel)

        let content = card.contentView

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Where to?"
        title.font = Self.rounded(27, .bold)
        title.textColor = .label
        content.addSubview(title)

        // Top-right icons: history + settings.
        historyButton.setImage(UIImage(systemName: "clock"), for: .normal)
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        let symCfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for b in [historyButton, settingsButton] {
            b.tintColor = .secondaryLabel
            b.setPreferredSymbolConfiguration(symCfg, forImageIn: .normal)
        }
        historyButton.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        let iconStack = UIStackView(arrangedSubviews: [historyButton, settingsButton])
        iconStack.axis = .horizontal
        iconStack.spacing = 20
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(iconStack)
        NSLayoutConstraint.activate([
            iconStack.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            iconStack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
        ])

        // Pill search field with a leading magnifier.
        fieldContainer.translatesAutoresizingMaskIntoConstraints = false
        fieldContainer.backgroundColor = .quaternarySystemFill
        fieldContainer.layer.cornerRadius = 26
        fieldContainer.layer.cornerCurve = .continuous
        content.addSubview(fieldContainer)

        let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass"))
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        magnifier.tintColor = .secondaryLabel
        magnifier.contentMode = .scaleAspectFit
        fieldContainer.addSubview(magnifier)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "Search or enter address"
        field.font = .systemFont(ofSize: 17)
        field.textColor = .label
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.keyboardType = .webSearch
        field.returnKeyType = .go
        field.clearButtonMode = .whileEditing
        field.delegate = self
        fieldContainer.addSubview(field)

        // Tab list — an Apple-style rounded, scrollable list of open tabs.
        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.backgroundColor = .quaternarySystemFill
        listContainer.layer.cornerRadius = 20
        listContainer.layer.cornerCurve = .continuous
        listContainer.clipsToBounds = true
        content.addSubview(listContainer)

        tabList.translatesAutoresizingMaskIntoConstraints = false
        tabList.backgroundColor = .clear
        tabList.separatorStyle = .singleLine
        tabList.separatorInset = UIEdgeInsets(top: 0, left: 52, bottom: 0, right: 0)
        tabList.rowHeight = 60
        tabList.showsVerticalScrollIndicator = false
        tabList.keyboardDismissMode = .onDrag
        tabList.dataSource = self
        tabList.delegate = self
        tabList.register(TabCell.self, forCellReuseIdentifier: TabCell.reuseID)
        listContainer.addSubview(tabList)

        NSLayoutConstraint.activate([
            solidBackdrop.topAnchor.constraint(equalTo: topAnchor),
            solidBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            solidBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            solidBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            blurBackdrop.topAnchor.constraint(equalTo: topAnchor),
            blurBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor).withPriority(.defaultLow),
            stack.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            stack.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9).withPriority(.defaultHigh),

            shadowHost.topAnchor.constraint(equalTo: card.topAnchor),
            shadowHost.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            shadowHost.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            shadowHost.trailingAnchor.constraint(equalTo: card.trailingAnchor),

            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(lessThanOrEqualTo: historyButton.leadingAnchor, constant: -12),

            fieldContainer.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 14),
            fieldContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            fieldContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            fieldContainer.heightAnchor.constraint(equalToConstant: 52),

            magnifier.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 16),
            magnifier.centerYAnchor.constraint(equalTo: fieldContainer.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 18),
            magnifier.heightAnchor.constraint(equalToConstant: 18),

            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: fieldContainer.topAnchor),
            field.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor),

            listContainer.topAnchor.constraint(equalTo: fieldContainer.bottomAnchor, constant: 16),
            listContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            listContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            listContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),

            tabList.topAnchor.constraint(equalTo: listContainer.topAnchor),
            tabList.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            tabList.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            tabList.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
        ])

        // Adaptive list height (updated in updateListHeight) + a bottom limit that
        // keeps the whole card above the keyboard.
        listHeight = listContainer.heightAnchor.constraint(equalToConstant: 0)
        listHeight.isActive = true
        cardBottom = stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        cardBottom.isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
        blurBackdrop.contentView.addGestureRecognizer(tap)

        // Keep the glass edge highlight correct across light/dark switches.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HomeOverlayView, _) in
            view.card.layer.borderColor = view.glassEdgeColor()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateListHeight()
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds, cornerRadius: 28).cgPath
    }

    /// List grows with the number of tabs, capped to the space above the keyboard;
    /// past the cap the list scrolls (card height stays fixed).
    private func updateListHeight() {
        // The tab list gives way to the panel when one is open.
        listContainer.isHidden = tabs.isEmpty || !panel.isHidden
        guard !listContainer.isHidden else {
            listHeight.constant = 0
            return
        }
        let intrinsic = CGFloat(tabs.count) * rowHeight
        let topInset = safeAreaInsets.top + 16
        let bottomInset = max(safeAreaInsets.bottom, keyboardHeight) + 16
        let availForCard = bounds.height - topInset - bottomInset
        let maxList = max(0, availForCard - chromeAboveList)
        let target = tabs.isEmpty ? 0 : min(intrinsic, maxList)
        if abs(listHeight.constant - target) > 0.5 {
            listHeight.constant = target
        }
        tabList.isScrollEnabled = intrinsic > target + 0.5
    }

    // MARK: - Data

    func setTabs(_ tabs: [Tab], current: UUID?) {
        self.tabs = tabs
        self.currentTabID = current
        tabList.reloadData()
        setNeedsLayout()
    }

    // MARK: - Keyboard

    @objc private func keyboardChanged(_ note: Notification) {
        guard !isHidden,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let kbInSelf = convert(end, from: nil)
        keyboardHeight = max(0, bounds.maxY - kbInSelf.minY)
        cardBottom.constant = -(16 + keyboardHeight)

        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) {
            self.updateListHeight()
            self.layoutIfNeeded()
        }
    }

    // MARK: - Presentation

    func present(over hasPage: Bool, animated: Bool) {
        isHidden = false
        solidBackdrop.alpha = hasPage ? 0 : 1
        blurBackdrop.alpha = hasPage ? 1 : 0
        field.text = ""

        let reveal = {
            self.card.transform = .identity
            self.card.alpha = 1
            self.shadowHost.transform = .identity
            self.shadowHost.alpha = 1
        }
        if animated {
            let start = CGAffineTransform(translationX: 0, y: 26).scaledBy(x: 0.95, y: 0.95)
            card.transform = start
            shadowHost.transform = start
            card.alpha = 0
            shadowHost.alpha = 0
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.86,
                           initialSpringVelocity: 0.5, options: [.curveEaseOut], animations: reveal)
        } else {
            reveal()
        }
        // Keyboard stays down until the user taps the field.
    }

    func dismiss(animated: Bool) {
        field.resignFirstResponder()
        panel.isHidden = true
        panel.alpha = 1
        let hideBlock = {
            self.solidBackdrop.alpha = 0
            self.blurBackdrop.alpha = 0
            self.card.alpha = 0
            self.shadowHost.alpha = 0
            let t = CGAffineTransform(translationX: 0, y: 18).scaledBy(x: 0.97, y: 0.97)
            self.card.transform = t
            self.shadowHost.transform = t
        }
        let done: (Bool) -> Void = { _ in
            self.isHidden = true
            self.card.transform = .identity
            self.shadowHost.transform = .identity
        }
        if animated {
            UIView.animate(withDuration: 0.22, animations: hideBlock, completion: done)
        } else {
            hideBlock(); done(true)
        }
    }

    @objc private func backdropTapped() {
        onDismiss?()
    }

    @objc private func historyTapped() { togglePanel(.history) }
    @objc private func settingsTapped() { togglePanel(.settings) }

    /// Tapping an icon opens its panel under the start box; tapping the same icon
    /// again closes it, the other icon swaps the content.
    private func togglePanel(_ mode: StartPanelView.Mode) {
        if !panel.isHidden && panel.mode == mode {
            hidePanel()
            return
        }
        field.resignFirstResponder()
        panel.show(mode)
        guard panel.isHidden else { return }   // already open: content swapped, no animation
        panel.alpha = 0
        panel.isHidden = false
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.88,
                       initialSpringVelocity: 0.4, options: [.curveEaseOut]) {
            self.panel.alpha = 1
            self.updateListHeight()      // collapse the tab list
            self.layoutIfNeeded()
        }
    }

    func hidePanel() {
        guard !panel.isHidden else { return }
        panel.isHidden = true            // so updateListHeight restores the tab list
        UIView.animate(withDuration: 0.22, animations: {
            self.panel.alpha = 0
            self.updateListHeight()
            self.layoutIfNeeded()
        }, completion: { _ in
            self.panel.alpha = 1
        })
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

// MARK: - UITextFieldDelegate

extension HomeOverlayView: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let text = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        onSubmit?(text)
        return true
    }
}

// MARK: - Tab list data source / delegate

extension HomeOverlayView: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tabs.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TabCell.reuseID, for: indexPath) as! TabCell
        let tab = tabs[indexPath.row]
        cell.configure(with: tab, isCurrent: tab.id == currentTabID)
        cell.onClose = { [weak self] in self?.onCloseTab?(tab.id) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectTab?(tabs[indexPath.row].id)
    }
}

// MARK: - Tab row

private final class TabCell: UITableViewCell {
    static let reuseID = "TabCell"

    var onClose: (() -> Void)?

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let urlLabel = UILabel()
    private let closeButton = UIButton(type: .system)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        let sel = UIView(); sel.backgroundColor = .quaternarySystemFill
        selectedBackgroundView = sel

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .secondaryLabel
        icon.contentMode = .scaleAspectFit
        contentView.addSubview(icon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(titleLabel)

        urlLabel.translatesAutoresizingMaskIntoConstraints = false
        urlLabel.font = .systemFont(ofSize: 13)
        urlLabel.textColor = .secondaryLabel
        urlLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(urlLabel)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.tintColor = .secondaryLabel
        let cfg = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        closeButton.setPreferredSymbolConfiguration(cfg, forImageIn: .normal)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),

            urlLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            urlLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            urlLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            closeButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 34),
            closeButton.heightAnchor.constraint(equalToConstant: 34),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with tab: Tab, isCurrent: Bool) {
        titleLabel.text = tab.title.isEmpty ? (tab.url.host ?? tab.url.absoluteString) : tab.title
        urlLabel.text = tab.url.host ?? tab.url.absoluteString
        if let favicon = tab.icon {
            icon.image = favicon
            icon.contentMode = .scaleAspectFit
            icon.tintColor = nil
            icon.layer.cornerRadius = 6
            icon.clipsToBounds = true
        } else {
            icon.image = UIImage(systemName: "globe")   // fallback until favicon loads
            icon.contentMode = .scaleAspectFit
            icon.tintColor = isCurrent ? .tintColor : .secondaryLabel
            icon.layer.cornerRadius = 0
        }
        titleLabel.textColor = isCurrent ? .tintColor : .label
    }

    @objc private func closeTapped() { onClose?() }
}

// MARK: - Small helpers

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
