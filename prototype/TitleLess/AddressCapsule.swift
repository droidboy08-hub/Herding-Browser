import UIKit

/// The one piece of chrome shown while a page is open.
///
/// It exists first to answer a question the app previously never answered:
/// *what site am I on?* A browser that never shows the origin cannot be used
/// safely — there is no way to tell a bank from a lookalike. Everything else it
/// does (a way into the start box, the page menu, the other tabs) is a
/// convenience bolted onto the surface that had to exist anyway.
///
/// It replaces the round refresh button. Reload moves to pull-to-refresh, which
/// is why nothing else lives in here: a single tap target is what lets the
/// capsule stay narrow enough to sit unobtrusively at the bottom of the screen.
final class AddressCapsule: UIView {

    var onTap: (() -> Void)?
    /// The long press has landed and the menu is opening.
    ///
    /// Reported rather than handled here because the capsule owns no haptics —
    /// the browser holds the generators, and this press has to feel distinct
    /// from a tap on the same surface.
    var onMenuOpen: (() -> Void)?
    /// +1 for the next tab, -1 for the previous one.
    var onSwitchTab: ((Int) -> Void)?

    /// The page menu, opened by a long press.
    ///
    /// A `UIMenu` can only be presented by a control that owns it, so the
    /// capsule carries an invisible button filling it rather than a long-press
    /// recogniser. Leaving `showsMenuAsPrimaryAction` off is what puts the menu
    /// on the *press* and leaves the tap free — the only split of the two UIKit
    /// supports.
    var menu: UIMenu? {
        get { button.menu }
        set { button.menu = newValue }
    }

    /// Bottom centre, not bottom-trailing. The trailing strip is where the
    /// forward-navigation edge swipe lives, and a left-swipe starting on a
    /// capsule pinned there would race it.
    static let height: CGFloat = 32
    /// Below roughly this, a swipe stops being distinguishable from a tap and
    /// tab-switching becomes unreliable. The floor is forced, not chosen.
    private static let minimumWidth: CGFloat = 104
    private static let horizontalPadding: CGFloat = 14

    private let glass = GlassSurface.makeView(radius: height / 2, interactive: true)
    private let label = UILabel()
    private let button = ExpandedHitButton(type: .system)
    /// The load indicator: a hairline inside the bottom edge rather than a fill
    /// sweeping across the capsule. A fill fights the material — `UIGlassEffect`
    /// refracts what is behind it and a tint over the whole capsule mutes
    /// exactly that — and it passes under the domain text at the moment the
    /// user is trying to read which site they are on.
    private let progress = CALayer()
    private var progressWidth: CGFloat = 0

    private var widthConstraint: NSLayoutConstraint!
    /// Drives the hide-on-scroll slide. Held so the two directions can't fight.
    private var isConcealed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        // The glass draws its own edge; the shadow is ours, and must not clip.
        layer.masksToBounds = false
        GlassSurface.applyFallbackShadow(to: self, opacity: 0.18, radius: 12,
                                         offset: CGSize(width: 0, height: 5))

        glass.translatesAutoresizingMaskIntoConstraints = false
        GlassSurface.applyFallbackEdge(to: glass,
                                       color: UIColor.white.withAlphaComponent(0.35).cgColor)
        glass.clipsToBounds = true          // so the hairline follows the corner
        addSubview(glass)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .label
        label.textAlignment = .center
        // Head, not tail. `…subdomain.example.com` keeps the part that says
        // whose site this is; truncating the other way renders `example.com…`
        // and hides exactly that.
        label.lineBreakMode = .byTruncatingHead
        glass.contentView.addSubview(label)

        progress.backgroundColor = UIColor.tintColor.cgColor
        progress.opacity = 0
        glass.contentView.layer.addSublayer(progress)

        widthConstraint = widthAnchor.constraint(equalToConstant: Self.minimumWidth)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.height),

            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.centerYAnchor.constraint(equalTo: glass.contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor,
                                           constant: Self.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor,
                                            constant: -Self.horizontalPadding),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button

        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = .clear
        button.showsMenuAsPrimaryAction = false      // menu on the press, tap stays free
        button.addAction(UIAction { [weak self] _ in self?.onMenuOpen?() },
                         for: .menuActionTriggered)
        // Press feel.
        //
        // On 26 the glass is already `isInteractive`, but the button fills the
        // capsule and takes every touch before the effect view sees one, so the
        // glass never deforms. Rather than fight the hit-testing, the press is
        // answered here — which also means 18, where there is no interactive
        // glass to deform at all, feels the same rather than feeling dead.
        button.addAction(UIAction { [weak self] _ in self?.setPressed(true) },
                         for: [.touchDown, .touchDragEnter])
        button.addAction(UIAction { [weak self] _ in self?.setPressed(false) },
                         for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        button.addAction(UIAction { [weak self] _ in self?.onTap?() },
                         for: .primaryActionTriggered)
        addSubview(button)
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // On the capsule, not the button: a recogniser on an ancestor still sees
        // touches that land in a descendant, and when it recognises it cancels
        // the button's tracking — so a flick changes tab instead of tapping.
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped))
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if layer.shadowOpacity > 0 {
            layer.shadowPath = UIBezierPath(roundedRect: bounds,
                                            cornerRadius: Self.height / 2).cgPath
        }
        layoutProgress()
    }

    /// Inside the bottom edge, inset to follow the corner radius rather than
    /// cutting a straight chord across it.
    private func layoutProgress() {
        let thickness: CGFloat = 2
        let inset = Self.height / 2 * 0.42
        let available = max(0, bounds.width - inset * 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progress.frame = CGRect(x: inset,
                                y: bounds.height - thickness - 1,
                                width: available * progressWidth,
                                height: thickness)
        progress.cornerRadius = thickness / 2
        CATransaction.commit()
    }

    // MARK: - Contents

    /// - Parameter url: the page's address, or nil when there is no page.
    ///
    /// Shows the full hostname with `www.` stripped — what Safari shows —
    /// rather than the shortened registrable domain. `RequestParty` already has
    /// a helper for the latter, and its own comment says its suffix list is not
    /// exhaustive and errs toward calling things third-party. Erring is fine for
    /// a blocking policy, where being wrong blocks slightly too much. It is not
    /// fine here, where being wrong tells someone they are on a site they are
    /// not on. A full hostname needs no suffix list and cannot be wrong.
    func show(url: URL?) {
        guard let url, let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            // Never invent a host: `file:` and `about:blank` get nothing.
            label.text = nil
            accessibilityLabel = nil
            isHidden = true
            return
        }
        isHidden = false
        // A capsule that was scrolled away and then hidden would come back
        // still translated off-screen, and never return.
        setConcealed(false, animated: false)
        let shown = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        label.text = shown
        // Plain http is marked, the way Safari marks it "Not Secure". The
        // domain is the thing being qualified, so the tint goes on the domain.
        label.textColor = scheme == "http" ? .systemOrange : .label
        accessibilityLabel = scheme == "http" ? "\(shown), not secure" : shown
        resize(for: shown)
    }

    private func resize(for text: String) {
        let width = (text as NSString)
            .size(withAttributes: [.font: label.font as Any]).width
        // Content-driven, with the swipe floor underneath it and a ceiling so a
        // long hostname can't take over the screen — past that it head-truncates.
        let ceiling = max(Self.minimumWidth, (superview?.bounds.width ?? 320) * 0.62)
        widthConstraint.constant = min(max(Self.minimumWidth,
                                           width + Self.horizontalPadding * 2), ceiling)
    }

    // MARK: - Loading

    func setProgress(_ value: Double, animated: Bool) {
        progressWidth = CGFloat(min(max(value, 0), 1))
        progress.opacity = 1
        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            layoutProgress()
            CATransaction.commit()
        } else {
            layoutProgress()
        }
    }

    func finishProgress() {
        setProgress(1, animated: true)
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        progress.opacity = 0
        CATransaction.commit()
        // Reset only once it is invisible, or the bar visibly rewinds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, progress.opacity == 0 else { return }
            progressWidth = 0
            layoutProgress()
        }
    }

    func resetProgress() {
        progress.removeAllAnimations()
        progress.opacity = 0
        progressWidth = 0
        layoutProgress()
    }

    // MARK: - Hiding while scrolling

    /// Give under the finger, and come back.
    ///
    /// Small on purpose: this is a 32pt control, and the same 0.9 a large button
    /// can take reads as a flinch at this size. The spring is what sells it —
    /// linear scaling feels like a state change, a spring feels like a surface.
    private func setPressed(_ pressed: Bool) {
        UIView.animate(springDuration: pressed ? 0.22 : 0.34,
                       bounce: pressed ? 0 : 0.28) {
            self.glass.transform = pressed
                ? CGAffineTransform(scaleX: 0.96, y: 0.9) : .identity
            self.label.transform = self.glass.transform
        }
    }

    /// Take the impact of a tab arriving.
    ///
    /// The card that flew in has faded by now, so without this the tab lands
    /// silently and the animation ends on nothing. A short squash and rebound
    /// is the capsule absorbing it — the same language as the press, so it
    /// reads as the same surface reacting rather than as a new effect.
    func acknowledgeArrival() {
        UIView.animate(springDuration: 0.18, bounce: 0) {
            self.glass.transform = CGAffineTransform(scaleX: 1.06, y: 0.82)
        } completion: { _ in
            UIView.animate(springDuration: 0.4, bounce: 0.45) {
                self.glass.transform = .identity
            }
        }
    }

    /// Slides out of the way, and back. Visibility only — the capsule never
    /// resizes on its way out, and its geometry never changes.
    func setConcealed(_ concealed: Bool, animated: Bool = true) {
        guard concealed != isConcealed else { return }
        isConcealed = concealed
        let move = {
            self.transform = concealed
                ? CGAffineTransform(translationX: 0, y: Self.height + 28)
                : .identity
            self.alpha = concealed ? 0 : 1
        }
        guard animated else { move(); return }
        UIView.animate(springDuration: 0.34, bounce: 0.1, animations: move)
    }

    // MARK: - Gestures

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        onSwitchTab?(swipe.direction == .left ? 1 : -1)
    }
}
