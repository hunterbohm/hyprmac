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
- `omniwmctl` frames use a bottom-left origin (Cocoa coordinates), so in its output a larger `y` is
  higher on the screen.
- The phone job may only query phones macOS already trusts (it checks usbmuxd for a pairing record
  first); never let it start pairing, which pops a "Trust This Computer?" prompt on the phone.
- No GitHub Actions on macOS runners and no schedules (`cc-actions-guard .` before pushing).
