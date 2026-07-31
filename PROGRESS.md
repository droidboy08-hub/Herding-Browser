# Custom Firefox Minimal — Progress

## Direction (reset 2026-07-31)

Build a **simple, good-looking minimal browser first**. No ad-block, no extra
features yet. **All future work stays within Apple's terms & policies.**

- **No tabs** — single web view.
- **Custom start page** — small centered box with URL/search field.
- **Swipe navigation** — edge-swipe = back/forward; swipe-down = reveal the start box.
- Ad/content blocking will come **later via Apple's own Content Filtering / Safari
  content-blocker APIs** — not bundled third-party engines.

### Removed (was GPL / App-Store-risky)

Everything uBlock-Origin-Lite-derived and the App-Store-risky media hacks are gone:
`ContentBlockerService`, `CosmeticFilterService`, `ubol-block.json`,
`ubol-cosmetic.json`, the `tools/` converters, `vendor/uBOL-home`, the
background-audio session + Page-Visibility spoof, and `UIBackgroundModes`.
Reason: uBOL is GPLv3 (incompatible with App Store) and the background-audio /
YouTube tricks risk rejection (guideline 2.5.4 / 5.2). See git for what was pulled.

## Current app — `prototype/` (standalone WKWebView, iPhone)

Builds + runs on iPhone 17 simulator and installs on device (iPhone 16 Pro, iOS 18.6).
Xcode project uses file-system-synchronized groups — drop a file in
`prototype/MinimalBrowser/` and it auto-joins the target.

| File | Role |
|------|------|
| `MinimalBrowserApp.swift` | SwiftUI app shell hosting the UIKit browser |
| `BrowserViewController.swift` | Single web view, swipe gestures, progress bar, popup + external-scheme guards |
| `HomeOverlayView.swift` | Centered "Where to?" start box |
| `URLResolver.swift` | URL vs DuckDuckGo search |
| `Info.plist` | Minimal (background modes removed) |
| `MBrowser.icon` | Xcode 26 Icon Composer app icon (`ASSETCATALOG_COMPILER_APPICON_NAME = MBrowser`) |

Bundle id `browsermini.browser`, team 2X3N668UKS (personal), deployment iOS 18.0.

## Current behavior (kept — standard, compliant browser UX)

- Tab-less UI, centered start box, keyboard auto-focus.
- URL load + DuckDuckGo search.
- Swipe-down reveals the start box; native edge-swipe back/forward.
- Status bar hidden app-wide; small safe-area top gap so content clears the Dynamic Island.
- Pinch-to-zoom disabled (viewport + scroll-view fallback); double-tap zoom + scroll intact.
- Load progress bar.
- Popup/new-window suppression + non-web-scheme (`itms-apps://` etc.) refusal — basic hardening, not ad-block.

## Build / run

Simulator:
```bash
cd prototype && xcodebuild -project MinimalBrowser.xcodeproj -scheme MinimalBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath ./build build
```

Device (Pankaj's iPhone; needs it connected + unlocked):
```bash
cd prototype && xcodebuild -project MinimalBrowser.xcodeproj -scheme MinimalBrowser -configuration Debug \
  -destination 'id=00008140-0008448C1184801C' -derivedDataPath ./build-device -allowProvisioningUpdates build \
  && xcrun devicectl device install app --device 00008140-0008448C1184801C \
     ./build-device/Build/Products/Debug-iphoneos/MinimalBrowser.app
```

## Roadmap

1. ✅ Minimal browser core (tab-less, start box, swipe nav).
2. ✅ Strip all ad-block / GPL / App-Store-risky code.
3. ⬜ **Good UI design pass** — polish the start box, typography, motion, empty state (next).
4. ⬜ History / recents, settings.
5. ⬜ Ad/content blocking via Apple Content Filtering (Safari content-blocker), Apple-compliant.
6. ⬜ Publishing prep — paid account, privacy policy, PrivacyInfo.

## Repo notes

- `vendor/firefox-ios` — Mozilla Firefox iOS (reference for a later BrowserKit-based fork).
- No git commits yet.
