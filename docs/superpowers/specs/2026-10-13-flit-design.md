# flit — design spec

Date: 2026-10-13

## Goal

A personal macOS window switcher in the spirit of [AltTab](https://alt-tab.app/):
hold a modifier, tap a key, see every open **window** (not app) as a thumbnail,
cycle, release to focus. Single user, no distribution, no telemetry.

## Scope

Everything AltTab exposes, built in milestones. Each milestone ends in a
daily-usable app.

| Milestone | Contents |
|---|---|
| M1 Core | hold-to-switch, per-window entries, MRU order, arrows/Esc/mouse, minimized + hidden + other-display windows, state badges, thumbnails, minimal preferences, menu-bar icon, launch at login |
| M2 Actions + filters | other-Space windows, fullscreen windows, windowless apps, app blacklist, close/minimize/fullscreen/hide/quit from the switcher |
| M3 Appearance | thumbnail / app-icon / title-list styles, size, theme, animation, which display shows the switcher |
| M4 Power | multiple shortcut profiles with per-profile filters, ⌘-Tab takeover, type-to-search, full-size preview |
| M5 Polish | trackpad gesture trigger, auto-update, localization — all low value for a personal build; not planned |

## Constraints and decisions

- **macOS 26+, Apple silicon.** Lets us use ScreenCaptureKit screenshots and
  `SMAppService` without fallbacks.
- **Swift 6, SwiftPM, no Xcode project.** Only Command Line Tools are installed.
  `scripts/build-app.sh` turns the SwiftPM binary into `Flit.app`.
- **Stable code signature.** TCC (Accessibility, Screen Recording) keys grants
  to the signing identity; ad-hoc signatures change every build and would
  reset the grants. `scripts/make-cert.sh` creates a self-signed
  "Flit Dev" code-signing certificate once; builds sign with it. Falls back to
  ad-hoc with a warning.
- **Menu-bar app** (`LSUIElement`), no Dock icon.
- **Default shortcut ⌥-Tab.** ⌘-Tab takeover is an opt-in setting because a
  hung flit would take the system switcher with it.
- **Private APIs are loaded with `dlsym`,** never linked directly, so a missing
  symbol degrades a feature instead of crashing at launch. Used for:
  `_AXUIElementGetWindow` (AX element → CGWindowID), `CGSCopySpacesForWindows` / `CGSGetActiveSpace` /
  `CGSCopyManagedDisplaySpaces` (which Space a window is on),
  `CGSSetSymbolicHotKeyEnabled` (disable the native ⌘-Tab).

## Architecture

```
┌──────────────┐  CGEvent tap   ┌───────────────┐  intents   ┌──────────────┐
│  KeyTap      │ ─────────────▶ │  Switcher     │ ─────────▶ │ WindowFocus  │
│ (Input/)     │  show/next/    │  Controller   │  focus/    │ (System/)    │
└──────────────┘  prev/commit   │ (App/)        │  close/…   └──────────────┘
                                │               │
┌──────────────┐  snapshot      │               │  state     ┌──────────────┐
│ WindowStore  │ ◀───────────── │               │ ─────────▶ │ SwitcherPanel│
│ (Model/)     │                └───────────────┘            │ + SwiftUI    │
│  ↑ AX, CG,   │                        ▲                    │ (UI/)        │
│  Screenshots │                        │ Preferences (observable, UserDefaults)
└──────────────┘                        └──────────────────────────────────────
```

### Units

- **`Model/WindowInfo`** — value type: `id: CGWindowID`, `pid`, `appName`,
  `bundleID`, `title`, `frame`, `isMinimized`, `isHidden` (app hidden),
  `isFullscreen`, `spaceIDs`, `isOnActiveSpace`, `screenID`, `axElement`,
  `thumbnail: CGImage?`, `lastFocused: Date`.
- **`Model/WindowStore`** — owns the list. `refresh()` enumerates
  `CGWindowListCopyWindowInfo(.optionAll)` (layer 0, alpha > 0, real size),
  joins with AX windows per app (title, minimized, element), tags Spaces via
  CGS. A CG window AX doesn't list is kept only if on screen or on another
  Space; otherwise it's a popup or leftover (Chrome omnibox, closed tabs).
  `_AXUIElementCreateWithRemoteToken` returns dead elements on macOS 26, so
  other-Space windows are CG-only entries. Background tabs of native tab
  groups are flagged `isTab` and hidden by default, and keeps MRU order from focus notifications
  (`NSWorkspace.didActivateApplicationNotification` + AX
  `kAXFocusedWindowChangedNotification` observers). Also exposes
  `apply(filter:)` which is pure and unit-tested.
- **`Model/WindowFilter`** — pure struct: flags for minimized, hidden, other
  Spaces, other displays (all / current cursor screen), fullscreen,
  windowless apps, blacklist, `currentAppOnly`, search query. `apply` returns
  the filtered + ordered list.
- **`System/AX`** — thin wrappers over `AXUIElement` (attributes, actions,
  observers) that return optionals instead of trapping.
- **`System/PrivateAPI`** — `dlsym` loader for the symbols listed above.
- **`System/Screenshots`** — ScreenCaptureKit single-window captures with a
  cache keyed by window ID; captures happen concurrently when the switcher
  opens, UI shows the previous capture (or the app icon) until fresh pixels
  arrive.
- **`System/WindowFocus`** — focus (unminimize, unhide, raise, activate; works
  across Spaces because raising an AX window switches Space), close,
  minimize, toggle fullscreen, hide app, quit app.
- **`Input/KeyTap`** — one session-level `CGEvent` tap. Idle: watches for any
  enabled profile's hold modifier + trigger key. Active: swallows all keys,
  routes Tab/Shift-Tab/arrows/Esc/letters/Space/Return to the controller,
  commits on modifier release. Re-enables itself if the system disables the
  tap on timeout. Optional ⌘-Tab takeover via `CGSSetSymbolicHotKeyEnabled`
  (restored on quit).
- **`Input/ShortcutProfile`** — Codable: `holdModifier` (⌥/⌘/⌃/fn), `key`
  (Tab, `` ` ``, Space, …), `mode` (`hold`: modifier release commits;
  `sticky`: stays open until Return/Esc/click), `filter` overrides, enabled.
  Defaults: ⌥-Tab all windows, ⌥-\` current app, ⌥-Space sticky search.
  Decoding is tolerant so older saved settings keep working.
- **`App/SwitcherController`** — the state machine: `hidden → open(profile)
  → selecting → commit | cancel`. Holds `selectedIndex`, `query`,
  `previewVisible`. Also handles mouse hover/click messages from the view.
- **`UI/SwitcherPanel`** — borderless non-activating `NSPanel`,
  `canJoinAllSpaces`, level above everything, placed on the configured
  screen. Hosts `SwitcherView`.
- **`UI/SwitcherView`** (SwiftUI) — renders one of three styles from the same
  `[WindowInfo]`: `thumbnails` (grid, wraps rows), `appIcons` (row of large
  icons + selected title), `titles` (vertical list). Badges: minimized,
  hidden, other Space. Search field appears when the query is non-empty.
- **`UI/PreviewPanel`** — shows the selected window's capture at its real
  frame, above other windows, toggled with Space.
- **`Preferences/Preferences`** — `ObservableObject` backed by UserDefaults
  with Codable blobs for profiles and blacklist. Observed by everything.
- **`Preferences/PreferencesWindow`** (SwiftUI) — tabs: General, Appearance,
  Filters, Shortcuts, Blacklist, Permissions.
- **`App/StatusBar`** — `NSStatusItem` menu: Preferences…, Permissions…,
  Launch at Login toggle, Quit.
- **`App/Permissions`** — checks `AXIsProcessTrusted` and
  `CGPreflightScreenCaptureAccess`, prompts, and deep-links to the right
  System Settings pane.

### Data flow (one switch)

1. Tap sees ⌥ held + Tab → `controller.open(profile)`; event swallowed.
2. Controller asks store for a fresh snapshot, applies the profile filter,
   selects index 1 (the previous window) — or 0 if only one window.
3. Panel shows on the configured screen; screenshots start concurrently and
   update entries as they land.
4. Tab / Shift-Tab / arrows move selection; W/M/F/H/Q run window actions
   (only while no search is active). Any other letter starts a search and
   makes the session **sticky** (Switch's "sticky picker", Contexts' search
   panel): the modifier can be released and typing continues.
5. ⌥ released → `commit` unless sticky. Return → commit. Esc → cancel.

### Error handling

- No Accessibility grant: the tap can't be created; status item shows a
  warning badge and a "Grant Accessibility…" item; the app keeps running and
  retries every 2 s until granted.
- No Screen Recording grant (the user's chosen setup): no API yields window
  pixels, so entries are cards in the window's real aspect ratio with icon
  and title, and the Space preview draws an accent outline at the window's
  frame. AX supplies titles (CG hides them without the grant).
- AX calls on an unresponsive app time out via `AXUIElementSetMessagingTimeout`
  (250 ms) so one frozen app can't freeze the switcher.
- Every private symbol lookup is optional; missing → feature off with a log
  line.

### Testing

- Unit tests (`swift test`): `WindowFilter.apply` (flags, blacklist, search
  matching, MRU order), `ShortcutProfile` codable + event matching, selection
  wraparound and grid navigation math.
- System integration can't be automated without permissions; verified by
  hand after `make install`.

## Build and run

```
make cert      # once: self-signed "Flit Dev" identity
make           # swift build -c release + Flit.app bundle, signed
make install   # copies to /Applications and relaunches
```
