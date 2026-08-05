import UIKit

/// The start page: a frosted-glass "window" floating in the middle of the frame
/// with a URL/search field and, below it, a scrollable list of open tabs (each
/// row has a close button). The only chrome in the app.
final class HomeOverlayView: UIView {

    var onSubmit: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    /// Fired once the box is actually off screen, whichever route closed it.
    /// Somewhere to put work that would be visible through the glass if it ran
    /// while the box was still up — a reload, for instance.
    var onDismissed: (() -> Void)?
    var onSelectTab: ((UUID) -> Void)?
    var onCloseTab: ((UUID) -> Void)?
    var onHistory: (() -> Void)?
    var onSettings: (() -> Void)?

    /// `ExpandedHitButton` rather than `UIButton`: these are 20pt glyphs 18pt
    /// apart along the top of the card, which is a 20pt target — under half
    /// Apple's 44pt minimum, and the reason they were awkward to hit. The
    /// expanded area overlaps between neighbours, and that is fine: hit-testing
    /// walks the subviews in reverse, so the overlap resolves to whichever is
    /// nearer the finger rather than to nothing.
    private let tabsButton = ExpandedHitButton(type: .system)
    private let downloadsButton = DownloadIconView(size: 21)
    private let historyButton = ExpandedHitButton(type: .system)
    private let bookmarksButton = BookmarkIconView(size: 20, strokeWidth: 2)
    private let settingsButton = ExpandedHitButton(type: .system)
    /// Which of them are on screen, and in what order, is a setting — so the
    /// row is filled in at run time rather than at build time.
    private let iconStack = UIStackView()

    private let solidBackdrop = UIView()
    /// Sits between the solid backdrop and the blur: over the plain background
    /// when there is no page behind, under the glass card either way.
    private let wallpaper = WallpaperView()
    private let blurBackdrop = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    /// Interactive: this is the surface you reach for, so it should give under
    /// a finger the way the system's own glass does.
    private let card = GlassSurface.makeView(radius: 28, interactive: true)
    private let shadowHost = UIView()
    private let fieldContainer = UIView()
    private let field = UITextField()
    private let stack = UIStackView()
    /// Sites kept under the search field. Hidden entirely when the setting is
    /// off, so the box is exactly what it was.
    let favourites = FavouritesBar()
    private var favouritesTop: NSLayoutConstraint!
    private var favouritesHeight: NSLayoutConstraint!
    /// Holds the start box and the panel as *one* piece of glass.
    ///
    /// Two independent glass views over the same backdrop each refract it on
    /// their own, so they read as two slabs that happen to be near each other. A
    /// container makes the system treat them as one material: they merge as the
    /// gap between them closes and separate as it opens, which is the behaviour
    /// the name "liquid" is describing.
    private let glassContainer = UIVisualEffectView(effect: nil)
    let panel = StartPanelView()   // second glass card (history / settings)

    private var tabs: [Tab] = []
    private var currentTabID: UUID?

    private var cardBottom: NSLayoutConstraint!   // keeps the card above the keyboard
    private var keyboardHeight: CGFloat = 0
    /// The panel's height, switched between two fixed sizes.
    private var panelHeight: NSLayoutConstraint!

    /// With the keyboard down there is most of a screen going spare, so the
    /// panel takes it — more history, more tabs, fewer settings scrolled past.
    private static let tallPanelHeight: CGFloat = 580
    /// With the keyboard up the panel has to fit in what is left above it, and
    /// this is the size that was there before either of them moved.
    private static let shortPanelHeight: CGFloat = 340
    /// How much keyboard counts as a keyboard.
    ///
    /// With a hardware keyboard attached, iOS still reports a keyboard frame —
    /// the shortcut bar, around 50pt — so a plain `> 0` test shrinks the panel
    /// for a keyboard that isn't taking any room. Anything shorter than this is
    /// that bar, not something to give half the screen back to.
    private static let keyboardIsUpThreshold: CGFloat = 120


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

        // Above the blur, not below it: a wallpaper *is* the backdrop when there
        // is one, and one sitting under the blur would come out as a smear of
        // its own colours rather than the picture that was chosen.
        wallpaper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wallpaper)

        shadowHost.translatesAutoresizingMaskIntoConstraints = false
        shadowHost.backgroundColor = .clear
        GlassSurface.applyFallbackShadow(to: shadowHost, opacity: 0.22, radius: 30,
                                         offset: CGSize(width: 0, height: 14))
        addSubview(shadowHost)

        card.translatesAutoresizingMaskIntoConstraints = false
        // Shape and edge come from the effect on real glass; the hairline is only
        // drawn on the material fallback, where nothing else would say where the
        // card ends.
        GlassSurface.applyFallbackEdge(to: card, color: glassEdgeColor())

        // Start box + optional panel live in a centered vertical stack, so opening
        // the panel pushes the start box up and the pair stays centered.
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill

        if #available(iOS 26.0, *) {
            // The two cards go inside the container's content view, which is
            // what puts them in the same glass "system".
            glassContainer.effect = UIGlassContainerEffect()
            glassContainer.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glassContainer)
            glassContainer.contentView.addSubview(stack)
            NSLayoutConstraint.activate([
                glassContainer.topAnchor.constraint(equalTo: topAnchor),
                glassContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
                glassContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
                glassContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        } else {
            addSubview(stack)
        }
        stack.addArrangedSubview(card)

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.isHidden = true
        // Fixed at one of two sizes; the content scrolls inside either way. Not
        // required priority: on a short screen the stack's own margins have to
        // win, or the layout is unsatisfiable rather than merely tight.
        panelHeight = panel.heightAnchor.constraint(
            equalToConstant: Self.tallPanelHeight)
        panelHeight.priority = .defaultHigh
        panelHeight.isActive = true
        panel.onClose = { [weak self] in self?.hidePanel() }
        stack.addArrangedSubview(panel)

        let content = card.contentView

        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Where to?"
        title.font = Self.rounded(27, .bold)
        title.textColor = .label
        content.addSubview(title)

        // Top-right icons. Which four is a setting; the controls are all built
        // here either way, so the ones out of the row keep their state (a
        // download running, a bookmark filled) and are correct the moment they
        // are put back in it.
        tabsButton.setImage(UIImage(systemName: "square.on.square"), for: .normal)
        historyButton.setImage(UIImage(systemName: "clock.arrow.circlepath"), for: .normal)
        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        let symCfg = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        for b in [tabsButton, historyButton, settingsButton] {
            b.tintColor = .secondaryLabel
            b.setPreferredSymbolConfiguration(symCfg, forImageIn: .normal)
        }
        downloadsButton.tintColor = .secondaryLabel
        bookmarksButton.tintColor = .secondaryLabel
        tabsButton.accessibilityLabel = StartBoxButton.tabs.name
        historyButton.accessibilityLabel = StartBoxButton.history.name
        settingsButton.accessibilityLabel = StartBoxButton.settings.name
        downloadsButton.accessibilityLabel = StartBoxButton.downloads.name
        bookmarksButton.accessibilityLabel = StartBoxButton.bookmarks.name
        tabsButton.addTarget(self, action: #selector(tabsTapped), for: .touchUpInside)
        downloadsButton.addTarget(self, action: #selector(downloadsTapped), for: .touchUpInside)
        historyButton.addTarget(self, action: #selector(historyTapped), for: .touchUpInside)
        bookmarksButton.addTarget(self, action: #selector(bookmarksTapped), for: .touchUpInside)
        settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)
        iconStack.axis = .horizontal
        iconStack.spacing = 18
        iconStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(iconStack)
        reloadStartBoxButtons()
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

        favourites.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(favourites)
        favouritesTop = favourites.topAnchor.constraint(
            equalTo: fieldContainer.bottomAnchor, constant: 14)
        favouritesHeight = favourites.heightAnchor.constraint(
            equalToConstant: FavouritesBar.rowHeight)

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

        NSLayoutConstraint.activate([
            solidBackdrop.topAnchor.constraint(equalTo: topAnchor),
            solidBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            solidBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            solidBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),

            wallpaper.topAnchor.constraint(equalTo: topAnchor),
            wallpaper.bottomAnchor.constraint(equalTo: bottomAnchor),
            wallpaper.leadingAnchor.constraint(equalTo: leadingAnchor),
            wallpaper.trailingAnchor.constraint(equalTo: trailingAnchor),

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
            title.trailingAnchor.constraint(lessThanOrEqualTo: iconStack.leadingAnchor, constant: -12),

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

            favouritesTop,
            favouritesHeight,
            favourites.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            favourites.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            favourites.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

        ])

        // Keep the stack above the keyboard.
        cardBottom = stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16)
        cardBottom.isActive = true

        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardChanged),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(downloadsChanged),
            name: DownloadManager.didChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(historyChanged),
            name: SQLiteHistory.didChangeNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(bookmarksChanged),
            name: BookmarkStore.didChangeNotification, object: nil)
        downloadsChanged()   // a download may already be running at launch

        let tap = UITapGestureRecognizer(target: self, action: #selector(backdropTapped))
        blurBackdrop.contentView.addGestureRecognizer(tap)

        // Keep the glass edge highlight correct across light/dark switches.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HomeOverlayView, _) in
            GlassSurface.applyFallbackEdge(to: view.card, color: view.glassEdgeColor())
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        shadowHost.layer.shadowPath = UIBezierPath(
            roundedRect: shadowHost.bounds, cornerRadius: 28).cgPath
    }

    /// Refill the icon row from the setting.
    ///
    /// The controls are reused rather than rebuilt: `removeFromSuperview` takes
    /// them out of the stack without releasing them, so the download icon keeps
    /// looping through a change and every target stays attached.
    func reloadStartBoxButtons() {
        iconStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for button in Settings.startBoxButtons {
            iconStack.addArrangedSubview(control(for: button))
        }
        // A panel left open on a mode whose button just left the row would have
        // no way to be closed from the row it came out of.
        if !panel.isHidden, let showing = StartBoxButton(mode: panel.mode),
           !Settings.startBoxButtons.contains(showing) {
            hidePanel()
        }
    }

    private func control(for button: StartBoxButton) -> UIView {
        switch button {
        case .tabs:      return tabsButton
        case .downloads: return downloadsButton
        case .history:   return historyButton
        case .bookmarks: return bookmarksButton
        case .settings:  return settingsButton
        }
    }

    /// Show or hide the favourites row, and rebuild it.
    ///
    /// The row is removed from the layout rather than emptied when it is off:
    /// an empty row still takes its height, and the start box would sit there
    /// with a band of nothing under the field.
    func reloadFavourites() {
        let wanted = Settings.showFavourites
        favourites.isHidden = !wanted
        favouritesHeight.constant = wanted ? FavouritesBar.rowHeight : 0
        favouritesTop.constant = wanted ? 14 : 0
        if wanted { favourites.reload() }
    }

    /// Pick up a wallpaper the user just chose.
    func reloadWallpaper() {
        wallpaper.reload()
        wallpaper.setPlaying(!isHidden)
    }

    // MARK: - Data

    func setTabs(_ tabs: [Tab], current: UUID?) {
        self.tabs = tabs
        self.currentTabID = current
        panel.setTabs(tabs, current: current)
    }

    // MARK: - Keyboard

    @objc private func keyboardChanged(_ note: Notification) {
        guard !isHidden,
              let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        else { return }
        let kbInSelf = convert(end, from: nil)
        keyboardHeight = max(0, bounds.maxY - kbInSelf.minY)
        // The panel gives its extra height back to the keyboard rather than
        // being squeezed by it: a compressed panel puts its own content into a
        // scroll view that is suddenly too short to show a whole row.
        panelHeight.constant = keyboardHeight >= Self.keyboardIsUpThreshold
            ? Self.shortPanelHeight : Self.tallPanelHeight
        cardBottom.constant = -(16 + keyboardHeight)

        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        UIView.animate(withDuration: duration) {
            self.layoutIfNeeded()
        }
    }

    // MARK: - Presentation

    func present(over hasPage: Bool, animated: Bool) {
        isHidden = false
        panel.historyChanged()      // whatever loaded while we were away
        solidBackdrop.alpha = hasPage ? 0 : 1
        blurBackdrop.alpha = hasPage ? 1 : 0
        // Shown whether or not a page is behind. Covering the page is the point:
        // the box is where you go to leave the page, and a wallpaper you only
        // ever see on a fresh launch is a wallpaper you never see.
        wallpaper.alpha = 1
        wallpaper.setPlaying(true)
        // The box opens with the keyboard down — it stays down until the field
        // is tapped — so the panel starts at the tall size. Without this it
        // would keep whatever height the last keyboard event left behind.
        keyboardHeight = 0
        panelHeight.constant = Self.tallPanelHeight
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
            self.wallpaper.alpha = 0
            self.card.alpha = 0
            self.shadowHost.alpha = 0
            let t = CGAffineTransform(translationX: 0, y: 18).scaledBy(x: 0.97, y: 0.97)
            self.card.transform = t
            self.shadowHost.transform = t
        }
        let done: (Bool) -> Void = { _ in
            self.isHidden = true
            // Nothing should be decoding video behind a web page.
            self.wallpaper.setPlaying(false)
            self.card.transform = .identity
            self.shadowHost.transform = .identity
            self.onDismissed?()
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

    @objc private func tabsTapped() { togglePanel(.tabs) }

    @objc private func downloadsTapped() {
        // The icon plays its drop-through-the-tray cycle once on tap; while a
        // transfer is actually running it keeps looping (see downloadsChanged).
        if !DownloadManager.shared.hasActiveDownloads { downloadsButton.playOnce() }
        togglePanel(.downloads)
    }

    /// Open Downloads from somewhere other than the icon (the Settings row).
    func showDownloads() { togglePanel(.downloads) }

    /// Open Settings without its button — the route the page menu offers when
    /// the gear has been taken out of the row.
    func showSettings() {
        guard panel.isHidden || panel.mode != .settings else { return }
        togglePanel(.settings)
    }

    /// A page finished loading behind the start box — repaint an open History list.
    @objc private func historyChanged() {
        panel.historyChanged()
    }

    /// Loop the icon while anything is in flight, and keep an open panel current.
    @objc private func downloadsChanged() {
        if DownloadManager.shared.hasActiveDownloads {
            downloadsButton.startAnimating()
        } else {
            downloadsButton.stopAnimating()
        }
        panel.downloadsChanged()
    }

    @objc private func historyTapped() {
        rewindHistoryIcon()
        togglePanel(.history)
    }

    /// The icon plays its own squash on touch — see `BookmarkIconView.tapped`.
    @objc private func bookmarksTapped() { togglePanel(.bookmarks) }

    /// A page was kept or dropped somewhere else — repaint an open list.
    @objc private func bookmarksChanged() {
        panel.bookmarksChanged()
    }

    /// History flourish: the icon winds backwards, then settles — a "rewind".
    private func rewindHistoryIcon() {
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseOut], animations: {
            self.historyButton.transform = CGAffineTransform(rotationAngle: -.pi / 4)   // -45°
        }, completion: { _ in
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
                self.historyButton.transform = .identity
            }
        })
    }
    @objc private func settingsTapped() {
        spinGear()
        togglePanel(.settings)
    }

    /// Gear flourish: one full turn with a soft ease, plus a brief scale pulse.
    private func spinGear() {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 0.9
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        settingsButton.layer.add(spin, forKey: "gearSpin")

        UIView.animate(withDuration: 0.3, animations: {
            self.settingsButton.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        }, completion: { _ in
            UIView.animate(withDuration: 0.3) {
                self.settingsButton.transform = .identity
            }
        })
    }

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

            self.layoutIfNeeded()
        }
    }

    func hidePanel() {
        guard !panel.isHidden else { return }
        panel.isHidden = true
        UIView.animate(withDuration: 0.22, animations: {
            self.panel.alpha = 0
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

// MARK: - Small helpers

private extension NSLayoutConstraint {
    func withPriority(_ p: UILayoutPriority) -> NSLayoutConstraint {
        priority = p
        return self
    }
}
