import MediaPlayer
import UIKit
import WebKit

extension Notification.Name {
    /// A media setting changed. `BrowserViewController` reinstalls the injected
    /// scripts and re-evaluates the transport controls when this fires.
    static let mediaSettingsChanged = Notification.Name("Herding.mediaSettingsChanged")
}

/// What the page's media elements are doing, as reported by the injected media
/// script.
struct MediaState {
    var title: String
    var isPlaying: Bool
    var duration: TimeInterval?
    var elapsed: TimeInterval?
}

/// Bridges the lock screen / Control Center transport controls to HTML5 media
/// inside the web view.
///
/// WebKit publishes Now Playing info itself for sites that implement the Media
/// Session API (YouTube does), and in that case the system talks to WebKit
/// directly. This fills the gap for everything else: a plain `<audio>`/`<video>`
/// element with no Media Session metadata, which otherwise gives the lock screen
/// nothing to show and no working play button.
///
/// Commands are registered once and torn down on deactivate — `addTarget`
/// accumulates handlers, so re-registering would fire the same command several
/// times per press.
final class RemoteMediaController {

    weak var webView: WKWebView?

    private var playTarget: Any?
    private var pauseTarget: Any?
    private var toggleTarget: Any?
    private(set) var isActive = false
    /// Whether the audio session is currently claimed. Tied to playback, not to
    /// the app's lifetime — see `beginPlayback()`.
    private(set) var isSessionActive = false

    /// Last known state, so Now Playing can be refreshed (artwork, elapsed time)
    /// without asking the page again.
    private var state = MediaState(title: "", isPlaying: false, duration: nil, elapsed: nil)

    // MARK: - Wiring

    func activate() {
        guard !isActive else { return }
        isActive = true

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true

        playTarget = center.playCommand.addTarget { [weak self] _ in
            self?.run(Self.playScript)
            return .success
        }
        pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
            self?.run(Self.pauseScript)
            return .success
        }
        // Headphone buttons and CarPlay send toggle rather than play/pause.
        toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.run(Self.toggleScript)
            return .success
        }
    }

    func deactivate() {
        endPlayback()
        guard isActive else { return }
        isActive = false

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(playTarget)
        center.pauseCommand.removeTarget(pauseTarget)
        center.togglePlayPauseCommand.removeTarget(toggleTarget)
        playTarget = nil; pauseTarget = nil; toggleTarget = nil
    }

    // MARK: - Audio session

    /// Claim the audio session, because media has actually started.
    ///
    /// Tying this to playback rather than to app launch matters twice over: a
    /// `.playback` session activated at launch stops whatever the user was
    /// already listening to in another app the moment the browser opens, and the
    /// `UIBackgroundModes: audio` declaration is only defensible while real,
    /// user-initiated audio is playing.
    func beginPlayback() {
        guard Settings.backgroundPlayback, !isSessionActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            isSessionActive = true
            // Required to receive transport events from the lock screen and
            // hardware controls.
            UIApplication.shared.beginReceivingRemoteControlEvents()
        } catch {
            print("[Media] audio session activation failed: \(error.localizedDescription)")
        }
    }

    /// Media finished or the page went away: release the session so a paused app
    /// in the background can pick its audio back up.
    func endPlayback() {
        clearNowPlaying()
        guard isSessionActive else { return }
        isSessionActive = false
        UIApplication.shared.endReceivingRemoteControlEvents()
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("[Media] audio session deactivation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Now Playing

    /// Publish what's playing. `artwork` is the site's favicon, which is the only
    /// image we have that actually represents the page.
    func updateNowPlaying(_ state: MediaState, artwork: UIImage? = nil) {
        self.state = state

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = state.title.isEmpty ? "Web Audio" : state.title
        if let duration = state.duration, duration.isFinite, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let elapsed = state.elapsed, elapsed.isFinite {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        // Without a rate the scrubber sits frozen even while audio plays.
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? 1.0 : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                artwork
            }
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        // An app without an AVPlayer has to state its transport state explicitly,
        // or the lock screen shows the wrong button.
        center.playbackState = state.isPlaying ? .playing : .paused
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Driving the page

    /// Remote command handlers are not guaranteed to arrive on the main thread,
    /// and `evaluateJavaScript` must be called there.
    private func run(_ script: String) {
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView else { return }
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    print("[Media] command failed: \(error.localizedDescription)")
                } else if result as? Bool == false {
                    print("[Media] no media element on the page")
                }
            }
        }
    }

    // MARK: - Scripts

    /// Pick the element the user is actually listening to: one that is playing,
    /// else one that has been played, else the first. A page can hold several
    /// media elements (autoplay previews, background loops), and taking
    /// `[0]` blindly usually grabs the wrong one.
    private static let pickElement = """
    var els = Array.prototype.slice.call(document.querySelectorAll('audio, video'));
    var el = els.filter(function(m) { return !m.paused && !m.ended; })[0]
          || els.filter(function(m) { return m.currentTime > 0; })[0]
          || els[0];
    """

    static let playScript = """
    (function() {
      \(pickElement)
      if (!el) { return false; }
      var p = el.play();
      if (p && p.catch) { p.catch(function() {}); }
      return true;
    })();
    """

    static let pauseScript = """
    (function() {
      \(pickElement)
      if (!el) { return false; }
      el.pause();
      return true;
    })();
    """

    static let toggleScript = """
    (function() {
      \(pickElement)
      if (!el) { return false; }
      if (el.paused) {
        var p = el.play();
        if (p && p.catch) { p.catch(function() {}); }
      } else {
        el.pause();
      }
      return true;
    })();
    """
}

// MARK: - BrowserViewController

extension BrowserViewController {

    /// Hook the lock screen / Control Center transport buttons up to the page.
    /// Only meaningful when background audio is on — with the session inactive
    /// the app never becomes the Now Playing app in the first place.
    func setupControlCenterAudioControls() {
        guard Settings.backgroundPlayback else {
            remoteMedia.deactivate()
            return
        }
        remoteMedia.webView = webViewForMediaControl
        remoteMedia.activate()
    }

    /// Called from the injected media script when a page's media starts, stops or
    /// ends.
    func handleMediaMessage(_ body: [String: Any]) {
        guard let stateName = body["state"] as? String else { return }

        if stateName == "ended" {
            remoteMedia.endPlayback()
            return
        }

        // Playback started: claim the audio session now, not before.
        if stateName == "play" {
            remoteMedia.beginPlayback()
        }
        // A pause keeps the session — the user may resume from the lock screen,
        // and dropping it would take the controls away mid-listen.

        let pageTitle = (body["title"] as? String) ?? ""
        let state = MediaState(
            title: pageTitle.isEmpty ? (webViewForMediaControl?.title ?? "") : pageTitle,
            isPlaying: stateName == "play",
            duration: body["duration"] as? TimeInterval,
            elapsed: body["time"] as? TimeInterval)

        remoteMedia.updateNowPlaying(state, artwork: currentTabIcon)
    }
}
