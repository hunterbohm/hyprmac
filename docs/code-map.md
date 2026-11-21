# HyprMac code map

What each file holds and the traps found while building it. `AGENTS.md` points here: read a file's
row before changing that file, and the function notes before changing the code they name.

## Layout

| Path | What it holds |
|---|---|
| `app/Sources/Config.swift` | hyprland.conf parser: variables, sections, binds, submaps, workspace rules, errors with line numbers |
| `app/Sources/Keys.swift` | modifier mapping (SUPER = Option by default) and the macOS keycode table |
| `app/Sources/KeyTap.swift` | the event tap: matches chords, swallows them, handles repeat, scroll and submaps |
| `app/Sources/Dispatchers.swift` | Hyprland dispatcher → `omniwmctl` translation |
| `app/Sources/OmniSettings.swift` | line-based TOML edits of OmniWM's settings (gaps, borders, animations, workspaces). Per-screen top gaps go in `[[monitorGapOverrides]]` rows whose `id` is derived from the display UUID (`gapRowId`); HyprMac only replaces rows with that id |
| `app/Sources/Modes.swift` | reading mode, record mode (recording stage) and prompter, ported from Hunter's AeroSpace scripts |
| `app/Sources/Tray.swift` | menu bar apps in OmniWM's bar: finds items over Accessibility (macOS 27: the children of MenuBarAgent's bar windows; macOS 26: each app's `AXExtrasMenuBar`), publishes `hyprmac_tray`, presses an item on `hyprmac://tray/<token>/<bundle>/<index>`, first making the clicked screen's menu bar the active one (only that screen's bar holds the real items). Items of a hidden menu bar can't be captured, so the widget shows app icons. See "Tray on macOS 27" below |
| `app/Sources/Notifications.swift` | stats the usernoted database every 2 s and fires `omniwmctl shell trigger notifications hyprmac-refresh` on change, because OmniWM 0.8's file watch misses those writes |
| `app/Sources/Banners.swift` | keeps Notification Center's full-screen window (AX subrole `AXSystemDialog`) moved down so banners start 16 points below OmniWM's bar (`omniwmctl query displays` bar frames); learns where macOS puts the banner list (`AXNotificationListItems`), skips while NC's panel is open (`widget-editor-button`), and moves it back on SIGTERM |
| `bar/notifications-patch.py` | install-time edit of OmniWM's own notifications widget (GPL, so ejected into the user's config and patched there, never copied into this repo): Clear All and × hide notifications in the bar, keeping their ids in the widget's `omniwm.store`, and a `trigger` re-reads on `hyprmac-refresh`. Clearing through Notification Center's panel was dropped: it flashed open and missed notifications it doesn't list. Marked by `.hyprmac` in the widget folder; a user's own copy is left alone |
| `app/Sources/main.swift` | daemon (reload on save, SIGHUP, error bar, submap pill) and the `hyprmac` / `hyprctl` CLI |
| `bar/battery-details/` | OmniWM's battery widget with a Devices section (iPhone, AirPods, keyboard); installed into `~/.config/omniwm/shell/widgets/` |
| `bar/tray/`, `bar/shell.toml` | the tray widget and the bar layout that places it; installed into `~/.config/omniwm/shell/`. The widget keeps pinned item ids (`<bundle>/<index>`) in its OmniWM store; the rest go in a drawer that opens on hover |
| `bar/device-batteries.py` | login agent, every minute: iPhone battery over Wi-Fi via libimobiledevice → `omniwmctl shell set hyprmac_devices` |
| `config/hyprland.conf` | the default config, shaped after Hunter's AeroSpace keys |
| `install.sh`, `uninstall.sh` | install and remove everything, including the login agents |

## Function notes

### `movewindow` and `moveDwindleWindow` (`app/Sources/Dispatchers.swift`)

- `movewindow` on Dwindle uses `move-column` (swaps with the neighbor tile, does nothing at an edge), never `move`: in Dwindle, `move` joins the neighbor's tab group and hides the other window. When nothing moved, `moveDwindleWindow` flips the split (`toggle-split`) and `swap-split`s if the window landed on the wrong side. Niri workspaces keep `move-column`.
- `moveDwindleWindow` never waits for the last animation when it can say where it ends. After each move it keeps the layout the move should produce (window id -> frame: a swap trades the two frames; a flip splits the pair's union rect along the other axis with the same gap and ratio) and decides the next press from that plus a fresh read of ids and focus; OmniWM's `frame` values are live (mid-flight), ids and focus are not. It falls back to `settledTiles` when the window ids changed, there is no prediction, or several tiles are in the move direction (unclear which one `move-column` swaps with). `toggle-split` + `swap-split` go out together (`omniwmctlTogether`): sent one process start apart, OmniWM animates toward the half-done layout and the windows hop the wrong way first. The workspace-layout and window queries also run together.

### The key tap (`app/Sources/KeyTap.swift`)

- The key tap's callback must return at once (macOS holds every key press until it does). `KeyTap.fire` logs `slow key tap` when a bound key takes over 1 ms. Binds queue on `Dispatchers.omniQueue` (serial, so presses run in order, `exec` included); submap changes happen in the callback, so the next key resolves against the new submap, and only their pill and `reload` hop to the main thread.

### Tray on macOS 27 (`app/Sources/Tray.swift`)

- Apps no longer publish `AXExtrasMenuBar`; only MenuBarAgent does, with Apple's items alone. The third-party items are the children of MenuBarAgent's AX windows (one bar per screen plus an empty shield window), each wrapping an element owned by the app (`AXUIElementGetPid`). The CGS window list shows one backdrop window, not one per item.
- Only the active screen's bar holds real items (an `AXButton` that `AXPress` opens). The other bars hold stand-ins: the wrapper's child is the app's whole `AXApplication`, and pressing it does nothing. `press` re-reads the bars at click time because the scan can be 3 s old.
- Items macOS tucks behind its own overflow arrow stay in the tree with stacked frames and still open on `AXPress`. Pressing MenuBarAgent's wrapper fails (-25206).
- Opening the `hyprmac://` link activates HyprMac. A menu that opens while HyprMac is active closes when macOS hands activation back, so `handle` gives activation back first (`yieldActivation` + `activate(from:)` to the app last deactivated; `NSApp.deactivate()` does nothing here), then presses.
- A live activity pill (`AXSubrole` `AXLiveActivity`) is MenuBarAgent's own and carries no bundle ID, only a label such as "T3 Code" for "T3 Code (Nightly)".
