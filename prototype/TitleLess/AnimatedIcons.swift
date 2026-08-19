import UIKit

/// The refresh flourish: one full clockwise turn with a soft ease. Shared by the
/// floating page-refresh button and the downloads retry button so both read as
/// the same control.
extension UIView {
    func spinOnce(duration: CFTimeInterval = 0.6) {
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = duration
        spin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(spin, forKey: "spin")
    }

    /// Keeps turning until stopped — a retry that's actually working.
    func startSpinning(duration: CFTimeInterval = 0.9) {
        guard layer.animation(forKey: "spinLoop") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = duration
        spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(spin, forKey: "spinLoop")
    }

    func stopSpinning() {
        layer.removeAnimation(forKey: "spinLoop")
    }
}

/// The download icon, drawn rather than an SF Symbol so the arrow can move
/// independently of the tray.
///
/// Animation cycle (1.5s, matching the reference motion spec):
/// 1. the arrow drops through the tray and fades, re-enters from above and
///    settles — the stem leads the head slightly, so the arrow reads as one
///    object falling rather than two shapes moving together;
/// 2. the tray takes the weight: a short dip plus a 5% swell, anchored at its
///    bottom edge;
/// 3. a 200ms beat before the next cycle.
///
/// `playOnce()` is the tap flourish, `startAnimating()` loops while a transfer
/// is running.
final class DownloadIconView: UIControl {

    private let tray = CAShapeLayer()
    private let stem = CAShapeLayer()
    private let head = CAShapeLayer()
    private let iconSize: CGFloat
    private var isLooping = false

    /// The reference artwork is drawn on a 24×24 grid; every offset below is
    /// expressed in those units and scaled to whatever size we're drawn at.
    private var unit: CGFloat { iconSize / 24 }

    init(size: CGFloat = 22, strokeWidth: CGFloat = 2) {
        iconSize = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        buildLayers(strokeWidth: strokeWidth)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: DownloadIconView, _) in
            v.applyStroke()
        }
        isAccessibilityElement = true
        accessibilityLabel = "Downloads"
        accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: iconSize, height: iconSize) }

    /// A 22pt icon is below the 44pt tap target, so widen the hit area instead of
    /// the artwork.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -11, dy: -11).contains(point)
    }

    override var tintColor: UIColor! {
        didSet { applyStroke() }
    }

    private func buildLayers(strokeWidth: CGFloat) {
        backgroundColor = .clear
        let s = unit

        // Tray: the open box the arrow falls into.
        let trayPath = UIBezierPath()
        trayPath.move(to: CGPoint(x: 21 * s, y: 15 * s))
        trayPath.addLine(to: CGPoint(x: 21 * s, y: 19 * s))
        trayPath.addQuadCurve(to: CGPoint(x: 19 * s, y: 21 * s),
                              controlPoint: CGPoint(x: 21 * s, y: 21 * s))
        trayPath.addLine(to: CGPoint(x: 5 * s, y: 21 * s))
        trayPath.addQuadCurve(to: CGPoint(x: 3 * s, y: 19 * s),
                              controlPoint: CGPoint(x: 3 * s, y: 21 * s))
        trayPath.addLine(to: CGPoint(x: 3 * s, y: 15 * s))

        let stemPath = UIBezierPath()
        stemPath.move(to: CGPoint(x: 12 * s, y: 3 * s))
        stemPath.addLine(to: CGPoint(x: 12 * s, y: 15 * s))

        let headPath = UIBezierPath()
        headPath.move(to: CGPoint(x: 7 * s, y: 10 * s))
        headPath.addLine(to: CGPoint(x: 12 * s, y: 15 * s))
        headPath.addLine(to: CGPoint(x: 17 * s, y: 10 * s))

        for (layer, path) in [(tray, trayPath), (stem, stemPath), (head, headPath)] {
            layer.path = path.cgPath
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = strokeWidth * s
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.frame = bounds
            self.layer.addSublayer(layer)
        }
        // The tray swells from its bottom edge, so it looks planted.
        tray.anchorPoint = CGPoint(x: 0.5, y: 1)
        tray.frame = bounds
        applyStroke()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for layer in [stem, head] { layer.frame = bounds }
        tray.frame = bounds
    }

    private func applyStroke() {
        // Resolved against the current traits, not left to `cgColor` to guess.
        //
        // A `CAShapeLayer` takes a `CGColor`, which is a fixed set of numbers —
        // it cannot carry "whatever `secondaryLabel` means here". Asking a
        // dynamic colour for its `cgColor` resolves it against whatever traits
        // are current at that instant, which during layer construction is often
        // not this view's. That is how this icon came to be drawn in dark
        // mode's grey while sitting in a light interface, a shade paler than
        // the SF Symbols beside it that UIKit keeps honest for us.
        let color = (tintColor ?? .label).resolvedColor(with: traitCollection).cgColor
        for layer in [tray, stem, head] { layer.strokeColor = color }
    }

    /// The stroke is a resolved CGColor, so it has to be re-resolved by hand when
    /// the interface style flips or the tint changes.
    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyStroke()
    }

    @objc private func tapped() { playOnce() }

    // MARK: - Motion

    func playOnce() {
        addCycle(repeating: false)
    }

    /// Loop while a transfer is in flight.
    func startAnimating() {
        guard !isLooping else { return }
        isLooping = true
        addCycle(repeating: true)
    }

    func stopAnimating() {
        guard isLooping else { return }
        isLooping = false
        for layer in [tray, stem, head] { layer.removeAnimation(forKey: "download") }
    }

    private func addCycle(repeating: Bool) {
        let drop = 8 * unit          // how far the arrow travels, in artwork units
        let dip = 2 * unit
        let cycle: CFTimeInterval = 1.5      // 1.0 arrow + 0.3 tray + 0.2 beat

        // Head trails the stem: same path, later key times.
        head.add(arrowAnimation(drop: drop,
                                keyTimes: [0, 0.4, 0.5, 0.6, 1],
                                cycle: cycle, repeating: repeating), forKey: "download")
        stem.add(arrowAnimation(drop: drop,
                                keyTimes: [0, 0.3, 0.4, 0.5, 1],
                                cycle: cycle, repeating: repeating), forKey: "download")

        // Tray reacts once the arrow has landed.
        let trayDip = CAKeyframeAnimation(keyPath: "transform.translation.y")
        trayDip.values = [0, dip, 0]
        trayDip.keyTimes = [0, 0.5, 1]
        let trayScale = CAKeyframeAnimation(keyPath: "transform.scale")
        trayScale.values = [1, 1.05, 1]
        trayScale.keyTimes = [0, 0.5, 1]
        for a in [trayDip, trayScale] {
            a.duration = 0.3
            a.beginTime = 1.0
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        }
        let trayGroup = CAAnimationGroup()
        trayGroup.animations = [trayDip, trayScale]
        trayGroup.duration = cycle
        trayGroup.repeatCount = repeating ? .infinity : 1
        trayGroup.isRemovedOnCompletion = !repeating
        tray.add(trayGroup, forKey: "download")
    }

    /// Drop out of the bottom, vanish, re-enter from the top, settle.
    private func arrowAnimation(drop: CGFloat,
                                keyTimes: [NSNumber],
                                cycle: CFTimeInterval,
                                repeating: Bool) -> CAAnimation {
        let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
        move.values = [0, drop, drop, -drop, 0]
        move.keyTimes = keyTimes

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0, 0, 0, 1]
        fade.keyTimes = keyTimes

        for a in [move, fade] {
            a.duration = 1.0
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = cycle
        group.repeatCount = repeating ? .infinity : 1
        group.isRemovedOnCompletion = !repeating
        return group
    }
}

// MARK: - Trash Icon

/// An animated trash can that opens its lid and shakes on tap.
final class TrashIconView: UIControl {
    private let bodyLayer = CAShapeLayer()
    private let lidLayer = CAShapeLayer()
    private let lidHost = CALayer()
    private let iconSize: CGFloat

    private var unit: CGFloat { iconSize / 24 }

    init(size: CGFloat = 22, strokeWidth: CGFloat = 1.5) {
        iconSize = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        buildLayers(strokeWidth: strokeWidth)
        isAccessibilityElement = true
        accessibilityLabel = "Clear History"
        accessibilityTraits = .button
        
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: TrashIconView, _) in
            v.applyStroke()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: iconSize, height: iconSize) }

    /// Increase click threshold
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -15, dy: -15).contains(point)
    }

    override var tintColor: UIColor! {
        didSet { applyStroke() }
    }

    private func buildLayers(strokeWidth: CGFloat) {
        backgroundColor = .clear
        let s = unit

        let bodyPath = UIBezierPath()
        bodyPath.move(to: CGPoint(x: 10 * s, y: 11 * s))
        bodyPath.addLine(to: CGPoint(x: 10 * s, y: 17 * s))
        bodyPath.move(to: CGPoint(x: 14 * s, y: 11 * s))
        bodyPath.addLine(to: CGPoint(x: 14 * s, y: 17 * s))
        bodyPath.move(to: CGPoint(x: 5 * s, y: 7 * s))
        bodyPath.addLine(to: CGPoint(x: 6 * s, y: 19 * s))
        bodyPath.addQuadCurve(to: CGPoint(x: 8 * s, y: 21 * s), controlPoint: CGPoint(x: 6 * s, y: 21 * s))
        bodyPath.addLine(to: CGPoint(x: 16 * s, y: 21 * s))
        bodyPath.addQuadCurve(to: CGPoint(x: 18 * s, y: 19 * s), controlPoint: CGPoint(x: 18 * s, y: 21 * s))
        bodyPath.addLine(to: CGPoint(x: 19 * s, y: 7 * s))

        bodyLayer.path = bodyPath.cgPath

        let lidPath = UIBezierPath()
        lidPath.move(to: CGPoint(x: 4 * s, y: 7 * s))
        lidPath.addLine(to: CGPoint(x: 20 * s, y: 7 * s))
        lidPath.move(to: CGPoint(x: 9 * s, y: 7 * s))
        lidPath.addLine(to: CGPoint(x: 9 * s, y: 4 * s))
        lidPath.addQuadCurve(to: CGPoint(x: 10 * s, y: 3 * s), controlPoint: CGPoint(x: 9 * s, y: 3 * s))
        lidPath.addLine(to: CGPoint(x: 14 * s, y: 3 * s))
        lidPath.addQuadCurve(to: CGPoint(x: 15 * s, y: 4 * s), controlPoint: CGPoint(x: 15 * s, y: 3 * s))
        lidPath.addLine(to: CGPoint(x: 15 * s, y: 7 * s))

        lidLayer.path = lidPath.cgPath

        for layer in [bodyLayer, lidLayer] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = strokeWidth * s
            layer.lineCap = .round
            layer.lineJoin = .round
        }

        layer.addSublayer(bodyLayer)

        lidHost.frame = bounds
        lidHost.addSublayer(lidLayer)
        // Transform origin 50% 100% relative to the lid bounding box (around y=7)
        lidHost.anchorPoint = CGPoint(x: 0.5, y: 7.0 / 24.0)
        layer.addSublayer(lidHost)

        applyStroke()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bodyLayer.frame = bounds
        lidLayer.frame = bounds
        lidHost.frame = bounds
    }

    private func applyStroke() {
        let color = (tintColor ?? .label).resolvedColor(with: traitCollection).cgColor
        bodyLayer.strokeColor = color
        lidLayer.strokeColor = color
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyStroke()
    }

    func playAnimation(completion: @escaping () -> Void) {
        let totalDuration: CFTimeInterval = 0.75
        let openTime = 0.25 / totalDuration
        let waitTime = 0.55 / totalDuration
        
        let rotate = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        rotate.values = [0, -30.0 * .pi / 180.0, -30.0 * .pi / 180.0, 0]
        rotate.keyTimes = [0, NSNumber(value: openTime), NSNumber(value: waitTime), 1]
        
        let moveY = CAKeyframeAnimation(keyPath: "transform.translation.y")
        moveY.values = [0, -5 * unit, -5 * unit, 0]
        moveY.keyTimes = rotate.keyTimes
        
        let moveX = CAKeyframeAnimation(keyPath: "transform.translation.x")
        moveX.values = [0, -2 * unit, -2 * unit, 0]
        moveX.keyTimes = rotate.keyTimes
        
        let timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        rotate.timingFunctions = timingFunctions
        moveY.timingFunctions = timingFunctions
        moveX.timingFunctions = timingFunctions

        let lidGroup = CAAnimationGroup()
        lidGroup.animations = [rotate, moveY, moveX]
        lidGroup.duration = totalDuration
        lidHost.add(lidGroup, forKey: "lid")

        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration) {
            completion()
        }
    }
}

// MARK: - Expanded Hit Button

/// A standard UIButton that increases its tap target area.
final class ExpandedHitButton: UIButton {

    /// Raw touch delivery, for a button that also shows a menu.
    ///
    /// `showsMenuAsPrimaryAction` makes UIKit own the button's press: no
    /// `.touchDown`, no `.touchUpInside`, nothing to hang a press animation or
    /// a hold timer on. `UIResponder`'s touch methods run before any of that
    /// and are unaffected by it, so they are what a control needing both a
    /// menu *and* a press has to use.
    var onTouchBegan: (() -> Void)?
    var onTouchEnded: (() -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        onTouchBegan?()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        onTouchEnded?()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        onTouchEnded?()
    }

    /// Apple's own floor for a tap target is 44×44 points. A 15pt inset around
    /// a 15pt glyph reaches about 45 — nominally fine, and in practice the
    /// close button on the panel was still hard to hit, because a target you
    /// have to be accurate about is one you notice. 22 puts the smallest of
    /// these comfortably past the floor rather than exactly on it.
    var hitInset: CGFloat = -22
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: hitInset, dy: hitInset).contains(point)
    }
}

/// The bookmark ribbon, drawn rather than taken from SF Symbols so it can be
/// squashed when it is used.
///
/// Ported from the reference component: one path on a 48×48 grid, and a squash
/// that scales the body to 90% vertically and drops it 2 units, anchored near
/// the top. 180ms out, 180ms back. The anchor is what sells it — pinned at 20%
/// down the shape, the ribbon compresses *into* the page rather than shrinking
/// in place, which is the difference between a bookmark being pushed in and an
/// icon being resized.
final class BookmarkIconView: UIControl {

    private let body = CAShapeLayer()
    private let iconSize: CGFloat

    /// Filled means kept. The squash animates the same either way — it is the
    /// same ribbon being pressed in, whether it is going onto the page or coming
    /// off it.
    var isFilled = false {
        didSet { applyStroke() }
    }

    /// The reference artwork is drawn on a 48×48 grid; every coordinate below is
    /// in those units and scaled to whatever size we're drawn at.
    private var unit: CGFloat { iconSize / 48 }

    init(size: CGFloat = 22, strokeWidth: CGFloat = 2) {
        iconSize = size
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isAccessibilityElement = true
        accessibilityTraits = .button
        buildLayer(strokeWidth: strokeWidth)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (v: BookmarkIconView, _) in
            v.applyStroke()
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: iconSize, height: iconSize) }

    /// A 22pt glyph is a small target; the row it sits in is not.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -12, dy: -12).contains(point)
    }

    private func buildLayer(strokeWidth: CGFloat) {
        body.path = Self.path(unit: unit)
        body.fillColor = UIColor.clear.cgColor
        body.lineWidth = strokeWidth
        body.lineCap = .square
        body.lineJoin = .miter
        body.miterLimit = 10
        // Anchored where the reference sets `transformOrigin: 50% 20%`, so the
        // squash pivots near the top of the ribbon rather than at its centre.
        body.anchorPoint = CGPoint(x: 0.5, y: 0.2)
        body.bounds = CGRect(x: 0, y: 0, width: iconSize, height: iconSize)
        layer.addSublayer(body)
        applyStroke()
    }

    /// `M24 34L41 44V8C41 5.23858 38.7614 3 36 3H12C9.23858 3 7 5.23858 7 8V44L24 34Z`
    /// — the reference path, with its two corner curves kept as the cubics they
    /// were authored as.
    private static func path(unit: CGFloat) -> CGPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * unit, y: y * unit) }
        let path = UIBezierPath()
        path.move(to: p(24, 34))
        path.addLine(to: p(41, 44))
        path.addLine(to: p(41, 8))
        path.addCurve(to: p(36, 3), controlPoint1: p(41, 5.23858), controlPoint2: p(38.7614, 3))
        path.addLine(to: p(12, 3))
        path.addCurve(to: p(7, 8), controlPoint1: p(9.23858, 3), controlPoint2: p(7, 5.23858))
        path.addLine(to: p(7, 44))
        path.close()
        return path.cgPath
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Position, not frame: the layer's anchor point is off-centre, so its
        // position has to land where that anchor should sit.
        body.position = CGPoint(x: bounds.midX,
                                y: bounds.midY - bounds.height * 0.3)
    }

    private func applyStroke() {
        let color = (tintColor ?? .label).resolvedColor(with: traitCollection).cgColor
        body.strokeColor = color
        body.fillColor = isFilled ? color : UIColor.clear.cgColor
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applyStroke()
    }

    @objc private func tapped() { playOnce() }

    /// The full gesture: squash, then release. What the reference plays across a
    /// hover in and out, run as one flourish — a phone has no hover, so the two
    /// halves have to be joined by time rather than by the pointer leaving.
    func playOnce() {
        let squash = CAKeyframeAnimation(keyPath: "transform")
        squash.values = [
            CATransform3DIdentity,
            CATransform3DConcat(CATransform3DMakeScale(1, 0.9, 1),
                                CATransform3DMakeTranslation(0, 2 * unit, 0)),
            CATransform3DIdentity,
        ]
        squash.keyTimes = [0, 0.5, 1]
        squash.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),      // in, as the reference has it
            CAMediaTimingFunction(name: .easeInEaseOut) // and back
        ]
        squash.duration = 0.36                          // 180ms each way
        body.add(squash, forKey: "squash")
    }

    /// The same artwork as a flat image, for the places that take a `UIImage`
    /// and not a view — menu items, table rows. Drawn from the one path so a
    /// bookmark looks like the same object wherever it appears.
    static func image(size: CGFloat = 20, strokeWidth: CGFloat = 2.4) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            context.cgContext.addPath(path(unit: size / 48))
            context.cgContext.setLineWidth(strokeWidth)
            context.cgContext.setLineCap(.square)
            context.cgContext.setLineJoin(.miter)
            context.cgContext.setMiterLimit(10)
            context.cgContext.setStrokeColor(UIColor.label.cgColor)
            context.cgContext.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }

    /// The filled variant, for a page that is already kept.
    static func filledImage(size: CGFloat = 20) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            context.cgContext.addPath(path(unit: size / 48))
            context.cgContext.setFillColor(UIColor.label.cgColor)
            context.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Liquid Glass

/// The glass surfaces: real Liquid Glass where the system has it, the old
/// material where it doesn't.
///
/// The two are not the same effect with different parameters. `UIBlurEffect`
/// blurs and tints what is behind it, and that is all it has ever done — which
/// is why a card built from it needs a hand-drawn hairline and a shadow to read
/// as an object at all. `UIGlassEffect` refracts the backdrop, lights its own
/// rim, adapts its tint to what it is over, and deforms under a finger. Those
/// borrowed decorations are exactly what makes it look imitated, so they come
/// off wherever the real thing is available.
enum GlassSurface {

    /// Whether the system can draw real glass.
    static var isAvailable: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// A glass view, cornered to `radius`.
    /// - Parameter interactive: whether it should react to touches. True for
    ///   things you press; false for a backdrop, which would otherwise wobble
    ///   when you tap the page behind it.
    /// - Parameter fallback: the material used before iOS 26.
    ///   `systemUltraThinMaterial` rather than `systemThinMaterial`: in light
    ///   mode the thin material is mostly white, which turns every card into a
    ///   pale slab and loses the wallpaper behind it. The ultra-thin one keeps
    ///   what is behind legible through it, which is the point of the material
    ///   and much nearer what the glass does on 26.
    static func makeView(radius: CGFloat,
                         interactive: Bool = false,
                         fallback: UIBlurEffect.Style = .systemUltraThinMaterial) -> UIVisualEffectView {
        if #available(iOS 26.0, *) {
            // `.clear` rather than `.regular`. The regular style is tuned to sit
            // over arbitrary content and stay legible, which in a light
            // interface means it fills with light — over a dark wallpaper that
            // reads as a pale slab rather than as glass. The clear style keeps
            // its transparency and lets what is behind actually come through,
            // which is the material people mean when they say liquid glass.
            let glass = UIGlassEffect(style: .clear)
            glass.isInteractive = interactive
            let view = UIVisualEffectView(effect: glass)
            // The effect draws its own edge and shading, so the view only has to
            // say what shape it is.
            view.cornerConfiguration = .corners(radius: .fixed(radius))
            return view
        }
        let view = UIVisualEffectView(effect: UIBlurEffect(style: fallback))
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        return view
    }

    /// The hairline that makes the old material read as a card. A no-op on real
    /// glass, which lights its own edge — drawing over it is what produced the
    /// "sticker" look.
    static func applyFallbackEdge(to view: UIVisualEffectView, color: CGColor) {
        guard !isAvailable else { return }
        view.layer.borderWidth = 1
        view.layer.borderColor = color
    }

    /// Likewise the drop shadow: real glass shades itself against what is
    /// behind it, and a second shadow underneath reads as a cut-out.
    static func applyFallbackShadow(to host: UIView,
                                    opacity: Float, radius: CGFloat, offset: CGSize) {
        guard !isAvailable else {
            host.layer.shadowOpacity = 0
            return
        }
        host.layer.shadowColor = UIColor.black.cgColor
        host.layer.shadowOpacity = opacity
        host.layer.shadowRadius = radius
        host.layer.shadowOffset = offset
    }
}
