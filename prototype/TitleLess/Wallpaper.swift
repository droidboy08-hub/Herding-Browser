import AVFoundation
import UIKit

/// What sits behind the start box.
enum WallpaperKind: String, Codable {
    case none
    /// One of the gradients that ship with the app.
    case preset
    /// One of the pictures that ship with the app.
    case builtIn
    case photo
    case video
}

/// A picture bundled with the app.
///
/// Files rather than an asset catalogue, and HEIC rather than PNG. A full-bleed
/// photograph for a 3x phone is around 1320×2868; as PNG that is several
/// megabytes each and the download grows by that much per wallpaper, while HEIC
/// at high quality is a fraction of it for a picture nobody is pixel-peeping
/// behind a frosted card. Loose files also mean the set is a folder you can add
/// to, with no catalogue to keep in step.
///
/// Every entry here has to be one the app has the right to ship: something
/// photographed by the developer, or licensed for redistribution inside an
/// application. Anything requiring attribution is credited under
/// Licences as well as listed here.
struct BuiltInWallpaper: Identifiable, Equatable {
    /// Stable, and persisted — renaming one changes what the user has chosen.
    let id: String
    /// Shown under the swatch.
    let name: String
    /// Basename of the bundled file, without extension.
    let file: String
    /// Who it belongs to, when that has to travel with it. `nil` means the app's
    /// own work, with nothing to credit.
    var credit: String? = nil

    var url: URL? {
        Bundle.main.url(forResource: file, withExtension: "heic")
            ?? Bundle.main.url(forResource: file, withExtension: "jpg")
    }

    /// What ships. Add a file to `Wallpapers/` and a line here — nothing else
    /// needs to change.
    ///
    /// Ordered by how well each one survives being cropped to a phone and sat
    /// behind a frosted card, not by anything about the pictures themselves:
    /// the ones with a subject in the middle and darkness around it come first,
    /// because that is what a start box wants behind it.
    static let all: [BuiltInWallpaper] = [
        BuiltInWallpaper(id: "monoliths", name: "Monoliths", file: "monoliths"),
        BuiltInWallpaper(id: "maelstrom", name: "Maelstrom", file: "maelstrom"),
        BuiltInWallpaper(id: "tether",    name: "Tether",    file: "tether"),
        BuiltInWallpaper(id: "causeway",  name: "Causeway",  file: "causeway"),
        BuiltInWallpaper(id: "watcher",   name: "Watcher",   file: "watcher"),
        BuiltInWallpaper(id: "undertow",  name: "Undertow",  file: "undertow"),
        BuiltInWallpaper(id: "aperture",  name: "Aperture",  file: "aperture"),
        BuiltInWallpaper(id: "sentinels", name: "Sentinels", file: "sentinels"),
        BuiltInWallpaper(id: "overlook",  name: "Overlook",  file: "overlook"),
    ]

    static func wallpaper(id: String) -> BuiltInWallpaper? {
        all.first { $0.id == id }
    }
}

/// Decodes bundled wallpapers at the size actually needed.
///
/// A full-resolution decode of every picture in the grid, to draw each one 92
/// points wide, is most of a screen's worth of memory for thumbnails. Image I/O
/// can decode straight to a size, which is both faster and smaller, so that is
/// what the grid and the view behind the start box both ask for.
enum WallpaperImageLoader {

    private static let cache = NSCache<NSString, UIImage>()

    /// - Parameter maxPixel: the longest edge wanted, in pixels. The whole
    ///   picture is decoded to fit inside it — nothing is cropped here, so a
    ///   caller that wants the picture whole gets it whole.
    static func image(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let key = "\(url.lastPathComponent)@\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }

    /// Big enough to fill this device's screen, and no bigger.
    static func fullScreen(at url: URL) -> UIImage? {
        let bounds = UIScreen.main.bounds.size
        let longest = max(bounds.width, bounds.height) * UIScreen.main.scale
        return image(at: url, maxPixel: longest)
    }
}

/// A wallpaper drawn in code rather than shipped as an image.
///
/// Gradients, not photographs, for three reasons that all point the same way:
/// nothing to license, nothing added to the download, and no resolution to pick
/// — a gradient is drawn at whatever size the screen turns out to be, on a phone
/// that doesn't exist yet as readily as on this one. They are also the right
/// backdrop for a glass card, which a busy photograph is not.
struct WallpaperPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let colors: [UIColor]
    /// Where the ramp runs from and to, in unit coordinates.
    let start: CGPoint
    let end: CGPoint

    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }

    /// The plain system background, sitting in the grid as a swatch so that
    /// "none" is chosen the same way every other wallpaper is — by looking at
    /// it and tapping it — rather than by a row further down the screen saying
    /// the opposite of what the grid says.
    static let system = WallpaperPreset(
        id: "system", name: "Default",
        colors: [UIColor.systemBackground, UIColor.secondarySystemBackground],
        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1))

    /// What the picker shows: the default first, then the gradients.
    static var pickable: [WallpaperPreset] { [system] + all }

    static let all: [WallpaperPreset] = [
        WallpaperPreset(id: "dusk", name: "Dusk",
                        colors: [rgb(0x1B2A4A), rgb(0x5B3A78), rgb(0xC2557A)],
                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
        WallpaperPreset(id: "ember", name: "Ember",
                        colors: [rgb(0x2A1220), rgb(0x8A3B2E), rgb(0xE8A05C)],
                        start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0)),
        WallpaperPreset(id: "moss", name: "Moss",
                        colors: [rgb(0x0F2A24), rgb(0x2C6E5A), rgb(0x8FC9A5)],
                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.6, y: 1)),
        WallpaperPreset(id: "tide", name: "Tide",
                        colors: [rgb(0x08243B), rgb(0x1B6E8C), rgb(0x7FD4D0)],
                        start: CGPoint(x: 0.2, y: 0), end: CGPoint(x: 0.8, y: 1)),
        WallpaperPreset(id: "ink", name: "Ink",
                        colors: [rgb(0x0B0B0D), rgb(0x2B2B31), rgb(0x4A4A55)],
                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
        WallpaperPreset(id: "paper", name: "Paper",
                        colors: [rgb(0xF6F2EA), rgb(0xE6DED2), rgb(0xCFC5B6)],
                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: 1)),
        WallpaperPreset(id: "bloom", name: "Bloom",
                        colors: [rgb(0x3B1E52), rgb(0x9B4D93), rgb(0xF2A0B6)],
                        start: CGPoint(x: 0, y: 1), end: CGPoint(x: 1, y: 0)),
        WallpaperPreset(id: "sand", name: "Sand",
                        colors: [rgb(0x6B4E2E), rgb(0xC08A4E), rgb(0xF0D9A8)],
                        start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0.4, y: 1)),
    ]

    static func preset(id: String) -> WallpaperPreset? {
        all.first { $0.id == id }
    }

    /// A thumbnail of the same gradient, for the picker.
    func thumbnail(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            let layer = CAGradientLayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.colors = colors.map(\.cgColor)
            layer.startPoint = start
            layer.endPoint = end
            layer.render(in: context.cgContext)
        }
    }
}

/// The chosen wallpaper: the file, and what kind of file it is.
///
/// Copied into Application Support rather than referenced in the photo library.
/// A library asset can be deleted, moved to iCloud, or need downloading before
/// it can be read — none of which is acceptable for something that has to be on
/// screen the instant the start box opens.
@MainActor
enum WallpaperStore {

    static let didChangeNotification = Notification.Name("WallpaperStore.didChange")

    private static let directory: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
        return support
    }()

    static var photoURL: URL { directory.appendingPathComponent("wallpaper.jpg") }
    static var videoURL: URL { directory.appendingPathComponent("wallpaper.mov") }

    /// Which built-in gradient is chosen, when one is.
    static var presetID: String? {
        get { UserDefaults.standard.string(forKey: "settings.wallpaperPreset") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "settings.wallpaperPreset") }
    }

    static var preset: WallpaperPreset? {
        guard kind == .preset, let presetID else { return nil }
        return WallpaperPreset.preset(id: presetID)
    }

    static func install(preset: WallpaperPreset) {
        presetID = preset.id
        kind = .preset
    }

    /// The gradient that belongs with a given interface style.
    ///
    /// Dark gets Ink and light gets the plain system one, because the two have
    /// to agree: the cards are clear glass, so whatever is behind them is what
    /// text is read against. A light interface over Ink is dark text on a dark
    /// backdrop, which is the one combination that cannot be made to work by
    /// adjusting the glass.
    static func paired(with mode: Settings.AppearanceMode) -> WallpaperPreset {
        switch mode {
        case .dark:
            return WallpaperPreset.preset(id: "ink") ?? .system
        case .light, .system:
            // The Default preset is built from `systemBackground`, which is a
            // dynamic colour — so it is already light in a light interface and
            // dark in a dark one. Following the system needs no observer,
            // because the wallpaper follows it on its own.
            return .system
        }
    }

    /// Follow the appearance, unless the wallpaper is something the user chose
    /// for its own sake.
    ///
    /// Only the two paired gradients are swapped. Anything else — another
    /// preset, a bundled picture, their own photo or video — was picked
    /// deliberately and is not ours to replace because a switch moved
    /// elsewhere.
    static func followAppearance(_ mode: Settings.AppearanceMode) {
        guard kind == .preset,
              presetID == "ink" || presetID == "system" else { return }
        let wanted = paired(with: mode)
        guard presetID != wanted.id else { return }
        install(preset: wanted)
    }

    /// Which bundled picture is chosen, when one is.
    static var builtInID: String? {
        get { UserDefaults.standard.string(forKey: "settings.wallpaperBuiltIn") }
        set { UserDefaults.standard.set(newValue, forKey: "settings.wallpaperBuiltIn") }
    }

    static var builtIn: BuiltInWallpaper? {
        guard kind == .builtIn, let builtInID else { return nil }
        return BuiltInWallpaper.wallpaper(id: builtInID)
    }

    static func install(builtIn wallpaper: BuiltInWallpaper) {
        builtInID = wallpaper.id
        kind = .builtIn
    }

    static var kind: WallpaperKind {
        get {
            UserDefaults.standard.string(forKey: "settings.wallpaperKind")
                .flatMap(WallpaperKind.init(rawValue:)) ?? .preset
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "settings.wallpaperKind")
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
            // The browser watches `appearanceChanged` — it is the same event as
            // far as anything on screen is concerned, and a wallpaper that
            // changed a store nobody was listening to is a wallpaper that never
            // appeared.
            NotificationCenter.default.post(name: .appearanceChanged, object: nil)
        }
    }

    /// Whether what sits behind the cards is light enough that text on them has
    /// to be dark — regardless of the appearance the user picked.
    ///
    /// `nil` means the wallpaper has no opinion, which is only the Default
    /// preset: it is built from `systemBackground`, a dynamic colour, so it is
    /// already whichever the interface is and there is nothing to resolve.
    ///
    /// The cards are clear glass. What is behind them is what their text is
    /// read against, which `paired(with:)` above already says in as many words
    /// — it just said it about one pair of gradients. Generalised: a light
    /// wallpaper under a dark interface put white labels on a cream card and
    /// made Home unreadable, and no amount of tuning the glass fixes a
    /// backdrop and a foreground that are the same brightness.
    ///
    /// Sampled once and remembered. The picture is decoded to 8 points on its
    /// longest edge for this, which is a hundred-odd pixels to average.
    static var backdropIsLight: Bool? {
        let signature = "\(kind.rawValue)|\(presetID ?? "")|\(builtInID ?? "")"
        if signature == cachedBrightnessKey { return cachedBrightness }

        let answer: Bool?
        switch kind {
        case .none:
            answer = nil
        case .preset:
            // The Default preset is the dynamic one; everything else is a fixed
            // ramp whose average is the whole answer.
            answer = presetID == "system" ? nil : preset.map(Self.isLight)
        case .builtIn:
            answer = builtIn?.url.flatMap { Self.isLight(imageAt: $0) }
        case .photo:
            answer = Self.isLight(imageAt: photoURL)
        case .video:
            answer = Self.videoIsLight
        }
        cachedBrightnessKey = signature
        cachedBrightness = answer
        return answer
    }

    private static var cachedBrightnessKey: String?
    private static var cachedBrightness: Bool?

    /// Above this, dark text on the card. Set at the midpoint rather than
    /// somewhere clever: a backdrop near enough to the middle to make the
    /// choice hard is one where either answer reads, and a threshold that
    /// wanders is worse than one that is simply consistent.
    /// `nonisolated` for the same reason `averageLuminance` is: the detached
    /// task that samples a video frame compares against it. A `let` holding a
    /// `CGFloat` has nothing to race over.
    private nonisolated static let lightThreshold: CGFloat = 0.5

    private static func isLight(_ preset: WallpaperPreset) -> Bool {
        let values = preset.colors.compactMap { $0.resolvedLuminance }
        guard !values.isEmpty else { return false }
        return values.reduce(0, +) / CGFloat(values.count) > lightThreshold
    }

    private static func isLight(imageAt url: URL) -> Bool? {
        guard let image = WallpaperImageLoader.image(at: url, maxPixel: 8),
              let cg = image.cgImage else { return nil }
        return averageLuminance(of: cg).map { $0 > lightThreshold }
    }

    /// A video's brightness, measured once when it is installed rather than
    /// every time the answer is wanted.
    ///
    /// Two reasons, and the deprecation is the smaller one. Pulling a frame out
    /// of a video is real work — decode a track, seek, render — and the caller
    /// is a synchronous property read during a layout pass, which is the worst
    /// possible place for it. Everything else here is arithmetic on a handful
    /// of bytes. So the frame is sampled off the main thread at install time
    /// and the verdict is all that is kept.
    ///
    /// `nil` until it lands, which means Home follows the appearance for the
    /// moment it takes; `.appearanceChanged` is posted when the answer arrives
    /// and Home re-reads it. Also nil for a video installed before this
    /// existed — `sampleVideoBrightnessIfNeeded` fills those in on first read.
    private static var videoIsLight: Bool? {
        get {
            sampleVideoBrightnessIfNeeded()
            return UserDefaults.standard.object(forKey: videoBrightnessKey) as? Bool
        }
        set { UserDefaults.standard.set(newValue, forKey: videoBrightnessKey) }
    }

    private static let videoBrightnessKey = "settings.wallpaperVideoIsLight"
    private static var samplingVideo = false

    /// Measure the installed video if its verdict is missing.
    static func sampleVideoBrightnessIfNeeded() {
        guard UserDefaults.standard.object(forKey: videoBrightnessKey) == nil,
              !samplingVideo,
              FileManager.default.fileExists(atPath: videoURL.path) else { return }
        samplingVideo = true

        let url = videoURL
        Task.detached(priority: .utility) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 8, height: 8)
            let light: Bool?
            if let cg = try? await generator.image(at: .zero).image {
                light = averageLuminance(of: cg).map { $0 > lightThreshold }
            } else {
                light = nil
            }
            await MainActor.run {
                samplingVideo = false
                guard let light else { return }
                videoIsLight = light
                // Whatever is on screen decided its legibility without this.
                cachedBrightnessKey = nil
                NotificationCenter.default.post(name: .appearanceChanged, object: nil)
            }
        }
    }

    /// Mean luminance of every pixel, drawn into a small known-format buffer so
    /// the bytes can be read without caring what the source was encoded as.
    ///
    /// `nonisolated` because the video path calls it from a detached task —
    /// it touches nothing but its arguments and a local buffer.
    private nonisolated static func averageLuminance(of image: CGImage) -> CGFloat? {
        let width = max(1, min(image.width, 8))
        let height = max(1, min(image.height, 8))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var total: CGFloat = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = CGFloat(pixels[index]) / 255
            let g = CGFloat(pixels[index + 1]) / 255
            let b = CGFloat(pixels[index + 2]) / 255
            total += 0.299 * r + 0.587 * g + 0.114 * b
        }
        return total / CGFloat(width * height)
    }

    /// The file currently in use, if there is one and it is still on disk.
    static var currentURL: URL? {
        let url: URL
        switch kind {
        case .none, .preset: return nil     // nothing on disk to point at
        // Bundled, not installed: it lives in the app, and handing it back here
        // would invite something to try to delete or overwrite it.
        case .builtIn: return nil
        case .photo: url = photoURL
        case .video: url = videoURL
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func install(photo image: UIImage) throws {
        // Re-encoded rather than copied: a modern phone photo is 4000px wide and
        // several megabytes, and this is only ever drawn at screen size.
        let scaled = image.scaled(toFit: UIScreen.main.bounds.size.scaled(by: 2))
        guard let data = scaled.jpegData(compressionQuality: 0.85) else {
            throw WallpaperError.couldNotEncode
        }
        try data.write(to: photoURL, options: .atomic)
        kind = .photo
    }

    static func install(videoAt source: URL) throws {
        try? FileManager.default.removeItem(at: videoURL)
        try FileManager.default.copyItem(at: source, to: videoURL)
        // The previous video's verdict belongs to a file that is gone.
        UserDefaults.standard.removeObject(forKey: videoBrightnessKey)
        kind = .video
        sampleVideoBrightnessIfNeeded()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: photoURL)
        try? FileManager.default.removeItem(at: videoURL)
        kind = .none
    }

    enum WallpaperError: LocalizedError {
        case couldNotEncode
        var errorDescription: String? { "That image couldn't be saved." }
    }
}

/// Draws the wallpaper behind the start box: a still, or a silent looping clip.
///
/// The video only runs while the box is on screen, which is the whole reason a
/// moving wallpaper is affordable here at all — the box is a thing you open for
/// a few seconds to type an address, not a screen you sit on. Playback stops the
/// moment it closes, so nothing decodes video behind a web page.
final class WallpaperView: UIView {

    private let imageView = UIImageView()
    private let gradient = CAGradientLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    /// Long enough to feel like a scene, short enough that the file stays small
    /// and the loop point comes back around before it gets boring.
    private let loopLimit = CMTime(seconds: 30, preferredTimescale: 600)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(gradient)
        gradient.isHidden = true
        imageView.contentMode = .scaleAspectFill
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layers don't lay themselves out, and neither of these should animate
        // into place on a rotation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        gradient.frame = bounds
        CATransaction.commit()
    }

    /// Rebuild from whatever the store now holds.
    func reload() {
        teardownVideo()
        imageView.image = nil
        gradient.isHidden = true

        if let preset = WallpaperStore.preset {
            gradient.colors = preset.colors.map(\.cgColor)
            gradient.startPoint = preset.start
            gradient.endPoint = preset.end
            gradient.isHidden = false
            isHidden = false
            return
        }

        // Bundled pictures come out of the app rather than out of Application
        // Support, and are decoded to screen size rather than to their own.
        if let builtIn = WallpaperStore.builtIn, let url = builtIn.url {
            imageView.image = WallpaperImageLoader.fullScreen(at: url)
            isHidden = imageView.image == nil
            return
        }

        guard let url = WallpaperStore.currentURL else {
            isHidden = true
            return
        }
        isHidden = false

        switch WallpaperStore.kind {
        case .photo:
            imageView.image = UIImage(contentsOfFile: url.path)
        case .video:
            buildVideo(from: url)
        case .none, .preset, .builtIn:
            isHidden = true
        }
    }

    private func buildVideo(from url: URL) {
        let item = AVPlayerItem(url: url)
        // Trimmed at the item rather than the file: the clip the user picked is
        // theirs and is left as it is.
        item.forwardPlaybackEndTime = loopLimit

        let queue = AVQueuePlayer()
        // Silent, and it must stay that way: an audio track here would take the
        // session away from whatever the user was listening to, for wallpaper.
        queue.isMuted = true
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item,
                                timeRange: CMTimeRange(start: .zero, end: loopLimit))

        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.insertSublayer(layer, at: 0)

        player = queue
        playerLayer = layer
    }

    private func teardownVideo() {
        player?.pause()
        looper?.disableLooping()
        playerLayer?.removeFromSuperlayer()
        player = nil
        looper = nil
        playerLayer = nil
    }

    /// Called when the start box appears and disappears. A still costs nothing
    /// either way; a clip costs a decoder, and only while it can be seen.
    func setPlaying(_ playing: Bool) {
        guard let player else { return }
        if playing {
            player.seek(to: .zero)
            player.play()
        } else {
            player.pause()
        }
    }
}

private extension UIImage {
    /// Downscale to fit, never up. Preserves aspect ratio.
    func scaled(toFit limit: CGSize) -> UIImage {
        let ratio = min(limit.width / size.width, limit.height / size.height, 1)
        guard ratio < 1 else { return self }
        let target = CGSize(width: size.width * ratio, height: size.height * ratio)
        return UIGraphicsImageRenderer(size: target).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

private extension CGSize {
    func scaled(by factor: CGFloat) -> CGSize {
        CGSize(width: width * factor, height: height * factor)
    }
}


private extension UIColor {
    /// Luminance, with a dynamic colour resolved first.
    ///
    /// `getRed` on a dynamic colour answers for whatever trait collection is
    /// current, which is exactly the circular reasoning this is trying to
    /// escape — so anything that varies by appearance is resolved against the
    /// light side and judged there.
    var resolvedLuminance: CGFloat? {
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return 0.299 * r + 0.587 * g + 0.114 * b
    }
}
