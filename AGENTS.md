# HyprMac

This repo makes a Mac feel like Hyprland. A small Swift agent (`app/Sources`) reads
`~/.config/hyprmac/hyprland.conf`, catches bound keys with a CGEvent tap, and runs each Hyprland
dispatcher through OmniWM's `omniwmctl`. It also writes the look-and-feel settings into OmniWM's
`~/.config/omniwm/settings.toml`. The README covers user-facing behavior.

## Layout

| Path | What it holds |
|---|---|
| `app/Sources/Config.swift` | hyprland.conf parser: variables, sections, binds, submaps, workspace rules, errors with line numbers |
| `app/Sources/Keys.swift` | modifier mapping (SUPER = Option by default) and the macOS keycode table |
| `app/Sources/KeyTap.swift` | the event tap: matches chords, swallows them, handles repeat, scroll and submaps |
| `app/Sources/Dispatchers.swift` | Hyprland dispatcher → `omniwmctl` translation |
| `app/Sources/OmniSettings.swift` | line-based TOML edits of OmniWM's settings (gaps, borders, animations, workspaces). Per-screen top gaps go in `[[monitorGapOverrides]]` rows whose `id` is derived from the display UUID (`gapRowId`); HyprMac only replaces rows with that id |
| `app/Sources/Modes.swift` | reading mode, record mode (recording stage) and prompter, ported from Hunter's AeroSpace scripts |
| `app/Sources/Tray.swift` | menu bar apps in OmniWM's bar: finds items over Accessibility (`AXExtrasMenuBar`), publishes `hyprmac_tray`, presses an item on `hyprmac://tray/<bundle>/<index>`, first making the clicked screen's menu bar the active one (macOS 26 keeps the items, drawn by Control Center, only there). Items of a hidden menu bar can't be captured, so the widget shows app icons |
| `app/Sources/Notifications.swift` | stats the usernoted database every 2 s and fires `omniwmctl shell trigger notifications hyprmac-refresh` on change, because OmniWM 0.8's file watch misses those writes |
| `app/Sources/Banners.swift` | keeps Notification Center's full-screen window (AX subrole `AXSystemDialog`) moved down so banners start 16 points below OmniWM's bar (`omniwmctl query displays` bar frames); learns where macOS puts the banner list (`AXNotificationListItems`), skips while NC's panel is open (`widget-editor-button`), and moves it back on SIGTERM |
| `bar/notifications-patch.py` | install-time edit of OmniWM's own notifications widget (GPL, so ejected into the user's config and patched there, never copied into this repo): Clear All and × hide notifications in the bar, keeping their ids in the widget's `omniwm.store`, and a `trigger` re-reads on `hyprmac-refresh`. Clearing through Notification Center's panel was dropped: it flashed open and missed notifications it doesn't list. Marked by `.hyprmac` in the widget folder; a user's own copy is left alone |
| `app/Sources/main.swift` | daemon (reload on save, SIGHUP, error bar, submap pill) and the `hyprmac` / `hyprctl` CLI |
| `bar/battery-details/` | OmniWM's battery widget with a Devices section (iPhone, AirPods, keyboard); installed into `~/.config/omniwm/shell/widgets/` |
| `bar/tray/`, `bar/shell.toml` | the tray widget and the bar layout that places it; installed into `~/.config/omniwm/shell/`. The widget keeps pinned item ids (`<bundle>/<index>`) in its OmniWM store; the rest go in a drawer that opens on hover |
| `bar/device-batteries.py` | login agent, every minute: iPhone battery over Wi-Fi via libimobiledevice → `omniwmctl shell set hyprmac_devices` |
| `config/hyprland.conf` | the default config, shaped after Hunter's AeroSpace keys |
| `install.sh`, `uninstall.sh` | install and remove everything, including the login agents |

## Rules

- Build with `app/build.sh OUTDIR`. `app/sign.sh` signs it with HyprMac's own local certificate
  (made once, kept in `~/.config/hyprmac/signing`), so macOS keeps the Accessibility switch across
  rebuilds. Never go back to ad-hoc signing: its requirement is the code hash, and every rebuild turned
  the switch off. The installer clears the old switch only when the signing certificate changed.
- Test in the hidden Mac (`ssh mini hidden-mac <job> ...`), never on Hunter's own screen. The test
  helpers (key and mouse sender, TCC grant script) live in the session scratch folder, not in this repo.
  Never run `osascript` against System Events there: it hangs on a hidden permission prompt.
- OmniWM's `settings.toml` uses a strict schema. Only set keys that exist in OmniWM's defaults, and keep
  its own hotkeys off (`hotkeysEnabled = false`) so the two don't fight over keys.
- `movewindow` on Dwindle uses `move-column` (swaps with the neighbor tile, does nothing at an edge), never `move`: in Dwindle, `move` joins the neighbor's tab group and hides the other window. When nothing moved, `moveDwindleWindow` flips the split (`toggle-split`) and `swap-split`s if the window landed on the wrong side. Niri workspaces keep `move-column`.
- `moveDwindleWindow` never waits for the last animation when it can say where it ends. After each move it keeps the layout the move should produce (window id -> frame: a swap trades the two frames; a flip splits the pair's union rect along the other axis with the same gap and ratio) and decides the next press from that plus a fresh read of ids and focus; OmniWM's `frame` values are live (mid-flight), ids and focus are not. It falls back to `settledTiles` when the window ids changed, there is no prediction, or several tiles are in the move direction (unclear which one `move-column` swaps with). `toggle-split` + `swap-split` go out together (`omniwmctlTogether`): sent one process start apart, OmniWM animates toward the half-done layout and the windows hop the wrong way first. The workspace-layout and window queries also run together.
- The key tap's callback must return at once (macOS holds every key press until it does). `KeyTap.fire` logs `slow key tap` when a bound key takes over 1 ms. Binds queue on `Dispatchers.omniQueue` (serial, so presses run in order, `exec` included); submap changes happen in the callback, so the next key resolves against the new submap, and only their pill and `reload` hop to the main thread.
- `omniwmctl` frames use a bottom-left origin (Cocoa coordinates), so in its output a larger `y` is
  higher on the screen.
- The phone job may only query phones macOS already trusts (it checks usbmuxd for a pairing record
  first); never let it start pairing, which pops a "Trust This Computer?" prompt on the phone.
- No GitHub Actions on macOS runners and no schedules (`cc-actions-guard .` before pushing).
