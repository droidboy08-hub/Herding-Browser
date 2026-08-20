# TitleLess — App Store Submission Guide

A step-by-step guide for getting **TitleLess** onto the App Store, written for
someone who has never shipped an app before.

**Read this once, top to bottom, before you start.** Nothing here is hard, but
the order matters — a few steps fail if an earlier one wasn't done.

---

## What this app is (for filling in forms later)

These are the real values, pulled from the project. Copy them exactly when a
form asks.

| Field | Value |
|---|---|
| App name | **TitleLess** |
| Bundle ID | `com.browser.TitleLess` |
| Version | `1.0` |
| Build number | `3` |
| Devices | iPhone **and** iPad |
| Minimum iOS | 18.0 |
| Developer / seller name | Baljinder Singh |
| Support email | support.titleless@gmail.com |
| Support URL | https://supporttitleless-dev.github.io/Titleless/support.html |
| Privacy Policy URL | https://supporttitleless-dev.github.io/Titleless/privacy.html |
| Marketing/Website URL | https://supporttitleless-dev.github.io/Titleless/ |
| Source repo | https://github.com/supporttitleless-dev/Titleless |

---

## The big picture — three stages

1. **One-time account setup** (only needed the very first time).
2. **Build & upload** the app from Xcode.
3. **Fill in the App Store Connect form** and hit Submit.

You do them in that order. You can start reading/preparing stage 3 while stage 2
uploads, but you can't *submit* until a build has finished uploading.

---

## Stage 0 — Prerequisites (check these first)

Tick each one before going further. If any is missing, sort it out first —
skipping ahead just fails later with a confusing error.

- [ ] **A Mac with Xcode installed.** (You have this — it's how the app was
  built.)
- [ ] **An Apple Developer Program membership.** This is the paid one — **$99 a
  year** — not the free Apple ID. Check at
  <https://developer.apple.com/account>. If it says "enroll", you are not a
  member yet and cannot submit anything until you join and pay.
- [ ] **The bundle ID `com.browser.TitleLess` is registered** in your developer
  account. Check at <https://developer.apple.com/account/resources/identifiers/list>.
  If it's not in the list, click **+**, choose **App IDs → App**, description
  "TitleLess", Bundle ID **Explicit** = `com.browser.TitleLess`, and Register.
  **This is the single most common thing to trip on — do it before you archive.**

> ⚠️ **Note:** an earlier version of this project used a *different* bundle ID
> (`com.nextbrowser.herding`). If you already created an app record in App Store
> Connect under that old ID, you cannot rename it. You'll create a **new** app
> record under `com.browser.TitleLess` (Stage 3). The old one can be deleted or
> left alone.

---

## Stage 1 — Create the app record in App Store Connect

*(Skip if you've already made one under `com.browser.TitleLess`.)*

1. Go to <https://appstoreconnect.apple.com> and sign in.
2. **Apps → the blue + → New App.**
3. Fill in:
   - **Platform:** iOS
   - **Name:** TitleLess *(this must be unique across the whole App Store — if
     it's taken, you'll be told, and you'll need a variant)*
   - **Primary language:** English (U.S.)
   - **Bundle ID:** select `com.browser.TitleLess` from the dropdown *(if it's
     not in the dropdown, the Stage 0 registration step wasn't done — go back)*
   - **SKU:** any private code you like, e.g. `titleless-01` (users never see
     this)
   - **User access:** Full Access
4. **Create.**

---

## Stage 2 — Build and upload (in Xcode)

This produces the actual app file and sends it to Apple. It has to be a
**Release** build, signed with your account — the simulator builds used during
development do **not** count.

1. Open the project in Xcode (`prototype/TitleLess.xcodeproj`).
2. **Xcode → Settings → Accounts** — make sure your Apple Developer account is
   listed. If not, click **+** and add it.
3. At the top of the Xcode window, click the **run destination** (next to the
   Play button) and change it to **Any iOS Device (arm64)**. You cannot archive
   while a simulator is selected — the Archive menu item stays greyed out.
4. Menu: **Product → Archive.** This takes a few minutes. It Release-builds and
   signs the app.
   - *If it fails to sign:* it's almost always the bundle ID not being
     registered (Stage 0) or the wrong team selected. Open the project's
     **Signing & Capabilities** tab, tick **Automatically manage signing**, and
     pick your Team.
5. When it finishes, the **Organizer** window opens showing your archive.
6. Click **Distribute App → App Store Connect → Upload → Next** through the
   prompts → **Upload.**
7. Wait. After it says done, the build still needs to **process** on Apple's
   side — usually 5–15 minutes, sometimes up to an hour. You'll get an email
   when it's ready, or you can watch **TestFlight** tab in App Store Connect.

> You cannot select the build in Stage 3 until processing finishes. This is
> normal — go make tea.

---

## Stage 3 — Fill in the App Store Connect form

Open your app in App Store Connect. There's a sidebar with sections. Work down
them.

### 3a. App Information (sidebar → General → App Information)

- **Subtitle** *(optional, 30 chars):* e.g. "A tab-less minimal browser"
- **Category:** Primary = **Utilities** (Secondary optional, e.g. Productivity)
- **Content Rights:** if the app contains no third-party copyrighted content,
  tick the box that says it does not. *(TitleLess renders the open web and ships
  open-source filter lists — it doesn't embed anyone's copyrighted media, so
  this is fine.)*
- **License Agreement:** **leave it alone.** Apple's standard EULA applies
  automatically. *(Verified against Apple's docs — you do not need your own.)*

### 3b. Pricing and Availability (sidebar → Pricing)

- Set the price. For free, pick **Free** (price tier 0).
- Availability: all countries, or narrow it if you want.

### 3c. App Privacy (sidebar → App Privacy)

This is the "privacy nutrition label." **It must match the app's privacy
manifest**, which declares the app collects nothing and tracks nobody.

- **Data Collection:** choose **"Data Not Collected."**
- That's it. Because the app truly collects no data (verified in
  `PrivacyInfo.xcprivacy`: no tracking, no collected data types), you don't fill
  in any data categories.
- **Privacy Policy URL:** `https://supporttitleless-dev.github.io/Titleless/privacy.html`

> ⚠️ Answer this honestly and consistently with the manifest. A mismatch between
> what you tick here and what the app's manifest declares is a known rejection
> cause.

### 3d. Age Rating (in the version page, or App Information)

Click **Edit** next to Age Rating and answer the questionnaire.

- Almost everything is **None**.
- **The one that matters:** there is a capability question about
  **"Unrestricted Web Access."** Answer **YES.** *(The app is a web browser —
  this is the honest answer, and Apple requires honesty here.)*
- Result: the app gets a **16+** rating. This is correct and expected for any
  browser. It is **not** a rejection risk — it's just the right rating.

*(Verified against Apple's current age-rating docs — the tiers are
4+/9+/13+/16+/18+, and unrestricted web access → 16+.)*

### 3e. The version page (sidebar → your version, e.g. "1.0 Prepare for
Submission")

- **Screenshots (required).** You need at least one set for a **6.9" iPhone**
  (the current largest). To make them: run the app in the iPhone simulator, get
  each screen looking right, and press **⌘S** (or Simulator → File → Save
  Screen) — that saves a correctly-sized PNG. Drag those into the screenshot
  box. *(If the app supports iPad — it does — Apple may also ask for iPad
  screenshots. Same method, iPad simulator.)*
- **Promotional Text** *(optional, editable any time)*.
- **Description.** What the app is. Mention: minimal, tab-less, gesture-driven,
  private, on-device ad & tracker blocking, no account, no analytics.
- **Keywords** *(100 chars, comma-separated)*: e.g.
  `browser,private,ad block,minimal,tabless,fast,tracker,privacy`
- **Support URL:** `https://supporttitleless-dev.github.io/Titleless/support.html`
- **Marketing URL** *(optional):* `https://supporttitleless-dev.github.io/Titleless/`
- **Build:** click **+** or **Select a build** and choose the one you uploaded
  in Stage 2. *(Only appears once processing has finished.)*

### 3f. App Review Information (same version page, scroll down)

- **Sign-in required?** No (the app has no login).
- **Contact info:** your name, phone, and `support.titleless@gmail.com`.
- **Notes (very important for this app):** TitleLess is deliberately
  gesture-driven with almost no on-screen buttons. **Tell the reviewer how to
  drive it**, or they may not figure it out and reject it. Suggested text:

  > TitleLess is a minimal, gesture-driven browser.
  > • Swipe DOWN on any page to open the address bar (the "start box").
  > • Type a URL or search and hit Go.
  > • The small capsule at the bottom of the screen shows the current site —
  >   tap it to open the address bar, long-press for the page menu, swipe it
  >   left/right to switch tabs.
  > • Settings, history, downloads and tabs are the icons along the top of the
  >   start box.
  > All web browsing uses WebKit (WKWebView). Ad/tracker blocking runs entirely
  > on-device; no data is collected or sent anywhere.

### 3g. Submit

- Top right: **Add for Review**, then **Submit for Review.**
- You'll get asked the **Export Compliance** question. The app uses only
  standard HTTPS encryption, which is exempt — the project already declares
  this (`ITSAppUsesNonExemptEncryption = false`), so you can answer that it uses
  no non-exempt encryption.

---

## What happens next

- Status goes to **Waiting for Review**, then **In Review**, then either
  **Ready for Sale / Pending Developer Release**, or **Rejected** with a reason.
- Review typically takes **24–48 hours**, sometimes faster.
- If rejected, Apple tells you exactly which guideline and why, in the
  **Resolution Center**. Most first-time rejections are small (a screenshot
  issue, a privacy-label mismatch, or "we couldn't figure out how to use it" —
  which the reviewer notes above are meant to prevent).

---

## Quick pre-flight checklist

Before you hit Submit, confirm:

- [ ] Developer Program membership active ($99/yr paid)
- [ ] Bundle ID `com.browser.TitleLess` registered in your account
- [ ] App record created under that exact bundle ID
- [ ] Build uploaded from Xcode and finished processing
- [ ] Build selected on the version page
- [ ] Screenshots added (6.9" iPhone at minimum; iPad too if asked)
- [ ] Description, keywords filled
- [ ] Support URL + Privacy Policy URL entered (both are live — verified)
- [ ] App Privacy = "Data Not Collected"
- [ ] Age rating done → "Unrestricted Web Access" = Yes → 16+
- [ ] Reviewer notes explaining the gestures added
- [ ] Export compliance answered (no non-exempt encryption)

---

## What was verified vs. what only you can confirm

**Verified in the code / against Apple's docs** (safe to rely on):

- Bundle ID is `com.browser.TitleLess` in the built app; the project compiles.
- Support and Privacy URLs return HTTP 200 (live).
- Privacy manifest declares no tracking and no data collection → "Data Not
  Collected" is the correct App Privacy answer.
- Encryption, orientation and version metadata are set.
- No GPL-licensed filter-list text is bundled in the binary.
- The app uses WebKit (WKWebView), satisfying App Review guideline **2.5.6**.
- "Unrestricted Web Access" → **16+** per Apple's current age-rating docs.
- A custom EULA is optional; the standard one applies if you leave it blank.

**Only you can confirm** (I could not check these — they depend on your Apple
account, not the code):

- That your Developer Program membership is active and paid.
- That `com.browser.TitleLess` is registered under *your* account.
- That signing works when you archive.
- Anything about the uploaded build — no Release archive has been produced yet;
  every build during development was a simulator (Debug) build.

---

## Still open (not blockers, but worth knowing)

- **`terms.html` does not exist** on the site (returns 404). This is fine —
  the app carries its own Terms offline, and Apple's standard EULA covers the
  store side. Only create a hosted terms page if you specifically want your own
  license agreement, which is pasted as plain text in App Store Connect (not a
  URL) if you ever do.
