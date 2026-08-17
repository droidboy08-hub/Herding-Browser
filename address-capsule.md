# Address Capsule — Specification

Status: **specified, not built.** Nothing in this document exists in the app yet.

A small permanent control at the bottom of the screen, replacing the round
refresh button. It shows which site you are on and is the way into the start
box, the page menu, and the other tabs.

---

## Why

Two problems, one control.

**Nothing on screen says what site you are on.** This is the important one. A
browser that never shows the origin cannot be used safely — the user has no way
to tell their bank from a lookalike. Every other browser shows it somewhere. The
start-box shortcut and the tab gesture are conveniences; this is the reason.

**The app has no visible affordances.** Everything is a gesture, and gestures
have to be taught. The Beta App Review notes have to explain to a reviewer how
to open the address field, which is a fair summary of the problem.

What it costs: the app is no longer chrome-free while a page is open. "Almost no
chrome on purpose" is in the App Store description and on the support page, and
both would need softening.

---

## Shape and placement

**Always the same size.** No expand-on-rest, no shrink-on-scroll. The capsule is
the smallest useful version of itself at all times. It hides and returns (below),
but its geometry never changes.

**Bottom centre.** Not bottom-trailing, where the current refresh button sits.
The trailing strip is where the forward-navigation edge swipe lives, and a
left-swipe starting on a capsule pinned there would race it.

**Roughly 100–130 × 32pt.** The width floor is forced rather than chosen: a
left/right swipe needs travel to be distinguishable from a tap, and below about
90–100pt the recogniser starts reading swipes as taps, making tab-switching
unreliable. The domain label takes it the rest of the way.

Nothing else lives inside the capsule — see *Reload* below.

Glass, matching the rest of the app: `UIGlassEffect` through
`GlassSurface.makeView`, as the refresh button already uses.

---

## Contents

### Domain

**The full hostname with `www.` stripped.** No scheme, no path — what Safari
shows.

Deliberately *not* the shortened registrable domain, despite
`RequestParty.registrableDomain` already existing. That helper's own comment
says its suffix list is not exhaustive and that it errs on the side of calling
things third-party. Erring is acceptable for a blocking policy, where being
wrong means blocking slightly too much. It is not acceptable here, where being
wrong means telling the user they are on a site they are not on. A full hostname
needs no suffix list and cannot be wrong.

**Truncate the head, not the tail** (`.byTruncatingHead`). `…subdomain.example.com`
keeps the part that identifies the site. Truncating the other way would render
`example.com…` and hide whose domain it actually is.

### Reload

**Pull-to-refresh, and nothing in the capsule.** No circular-arrow glyph, no
button. Drag down at the top of a page to reload it, the way every browser also
offers. This becomes the swipe's default job — see *`swipeDownAction` becomes a
toggle* below.

This keeps the capsule to a single tap target, which is what lets it stay as
narrow as it does.

Two things follow from it:

- **The capsule needs no trailing glyph**, so the width floor drops by about
  28pt to the swipe minimum.
- **Stopping a load has no home.** The glyph would have doubled as a stop
  control while loading, which is how Safari, Brave and Edge all handle it.
  Without it there is no way to abort a slow page except to navigate away.
  Whether that matters is undecided — see *Open questions*.

### Loading

**A hairline inside the bottom edge**, full width, about 2pt, inset to follow
the corner radius rather than cutting a straight chord across it.

Not a fill sweeping across the capsule. A fill works against the material —
`UIGlassEffect` refracts what is behind it, and a tint laid over the whole
capsule mutes exactly that. It also passes under the domain label, changing the
contrast beneath the text at the moment the user is trying to read which site
they are on. And it is loud: loading happens on every navigation, and a
whole-element colour change is a large event for a routine one. Safari used the
fill years ago and moved away from it.

The existing progress ring is dropped. It exists to wrap a circular button, and
there is no longer a circular button or a collapsed state to put it on.

Two problems at this size, both of which would apply to any indicator:

- **Very little travel.** A capsule this narrow gives the line almost no distance
  to cover, so a cached load is a flicker that reads as a glitch. Either give it a
  minimum duration so it always animates visibly, or suppress it below a
  threshold — Safari hides progress on fast loads for this reason.
- **`estimatedProgress` arrives in lurches**, not smoothly. A line absorbs that
  better than a fill would.

---

## Hiding while scrolling

**Scrolling down hides it. Scrolling up brings it back.** So does reaching the
top of the page. This is what Safari, Chrome and Firefox all do, and the
direction is not arbitrary: scrolling down means reading forward and wanting the
content, while scrolling up is already the gesture people associate with
reaching for browser chrome.

Visibility only — the capsule does not resize on its way out. It slides down past
the bottom edge and back.

**Not "reappears when scrolling stops."** Pausing mid-page is ordinary reading
behaviour, and a capsule that slides back over the text every time the user stops
to read a paragraph is exactly the interruption this app exists to avoid. Safari
deliberately does not do this either. Scroll up or reach the top; those are the
triggers.

The consequence worth stating: while hidden, the origin is not visible. That is
an acceptable trade — a user mid-scroll is reading, not evaluating who they are
talking to — and a single upward scroll restores it.

---

## Gestures

| Gesture | Action |
|---|---|
| Tap | Open the start box |
| Long press | The existing page menu, unchanged |
| Swipe left / right | Previous / next tab |

Swipe does nothing when only one tab is open.

Reload is not among these — it is pull-to-refresh on the page itself.

---

## Start box integration

Tapping the capsule expands into the start box, animating out of the capsule's
own frame. `UIGlassContainerEffect` — already used in `HomeOverlayView` — is what
makes glass shapes morph as they resize, so the transition uses machinery that
is already in the project.

**The start box opens carrying the current URL**, selected for editing, and
committing loads **in the same tab**.

This is the one part that changes existing behaviour rather than adding to it.
The start box currently calls `tabManager.addTab(url:)` on every commit, so
every address becomes a new tab. That has to stay true when the box is opened by
swipe-down or by "New Tab", and become false when it is opened from the capsule.
So the start box needs a mode — an editing session that targets the current tab —
rather than a change to how it commits.

---

## Edge cases

| State | Capsule shows |
|---|---|
| No page loaded | Hidden, as the refresh button is today |
| `file:` / `about:blank` | Nothing — never invent a host |
| Plain `http:` | Domain in a warning tint; Safari marks these "Not Secure" |
| Long hostname | Head-truncated, tail always visible |
| Single tab | Swipe is inert |

---

## Interactions with what exists

- **Replaces `refreshButton`** entirely — its glass, shadow, long-press menu and
  `hasLoadedPage` show/hide logic are the starting point, not the ring.
- **`Settings.startPage == .startBox`** currently hides the refresh button
  ([BrowserViewController.swift:414](prototype/Herding/BrowserViewController.swift:414)).
  The same question applies to the capsule and has not been decided.
- **The support page and App Store description** both describe reload as "the
  round button in the bottom corner", and the support page teaches the
  swipe-down gesture as the way to reach Home. Both would need rewriting.

### `swipeDownAction` becomes a toggle

**Decided.** The swipe no longer opens Home by default. It refreshes, as it does
in every other browser, and a setting can give Home back to it.

Today this is a two-option picker — *open Home* or *refresh* — and it has to be
neutral, because whichever you pick you lose the other. Home was only reachable
by that gesture, and refresh only by that gesture, so neither could be the
default without taking something away.

The capsule removes that symmetry. Home is now always one tap away, so declining
the gesture costs nothing. That turns an even choice into a plain default:

| | Swipe down does |
|---|---|
| Toggle off *(default)* | Pull to refresh |
| Toggle on | Open Home |

Wording along the lines of *"Also open Home by swiping down"*, in Home &
Appearance beside the existing swipe sensitivity slider.

**The residual, stated plainly:** with the toggle on, the swipe is spoken for and
reload has no gesture at all — the capsule carries no reload glyph to fall back
on. That is acceptable for something opt-in, but it means the switch really reads
"give Home the swipe, and give up reload's". Worth saying so in the footer rather
than letting people discover it.

---

## Open questions

1. Is having no way to stop a loading page acceptable?
2. Does the capsule appear when `startPage == .startBox`, as the refresh button
   does not?
