# flit

A personal macOS window switcher in the spirit of [AltTab](https://alt-tab.app/):
hold ⌥, tap Tab, see every window as a thumbnail, release to focus.

Requires macOS 14+ (built on 26) and only the Command Line Tools — no Xcode.

## Build

```
make cert      # once: creates a self-signed "Flit Dev" signing identity so
               # the Accessibility / Screen Recording grants survive rebuilds
make install   # builds, signs, copies to /Applications, launches
make test      # unit tests (filtering, search, shortcut matching, layout)
```

On first launch grant **Accessibility** (required) and **Screen Recording**
(for thumbnails) in System Settings → Privacy & Security. Flit retries the
event tap every 2 s until Accessibility is granted; no relaunch needed.
If a grant doesn't stick, remove Flit from the list, re-add it, relaunch.

## Use

| Keys (while holding ⌥) | Action |
|---|---|
| Tab / Shift-Tab, arrows | move selection |
| release ⌥ or Return | focus the selected window |
| Esc | cancel |
| ⌥ ` | switch between windows of the current app only |
| letters / digits | search by app name or title (subsequence match) |
| W / M / F / H / Q | close / minimize / fullscreen / hide app / quit app (when not searching) |
| Space | full-size preview of the selected window |
| mouse hover / click | select / focus |

Preferences live in the menu-bar icon: shortcut profiles with per-profile
filters (minimized, hidden, other Spaces, fullscreen, windowless apps, display
scope, current-app-only), three styles (thumbnails, app icons, titles), theme,
size, which display, badges, app blacklist, launch at login, and an opt-in
replacement of the system ⌘-Tab.

## Layout

- `Sources/Flit/Model` — `WindowInfo`, `WindowFilter` (pure), `WindowStore` (enumeration + MRU)
- `Sources/Flit/System` — AX wrappers, dlsym-loaded private APIs (Spaces, remote AX tokens, ⌘-Tab hotkey), ScreenCaptureKit thumbnails, window actions
- `Sources/Flit/Input` — CGEvent tap, shortcut profiles
- `Sources/Flit/App` — `SwitcherController` state machine, delegate, status bar, permissions
- `Sources/Flit/UI` — switcher and preview panels, SwiftUI views
- `Sources/Flit/Preferences` — settings model and window
- `docs/superpowers/specs` — design spec
