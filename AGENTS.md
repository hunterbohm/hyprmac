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
| `app/Sources/OmniSettings.swift` | line-based TOML edits of OmniWM's settings (gaps, borders, animations, workspaces) |
| `app/Sources/Modes.swift` | reading mode, record mode (recording stage) and prompter, ported from Hunter's AeroSpace scripts |
| `app/Sources/main.swift` | daemon (reload on save, SIGHUP, error bar, submap pill) and the `hyprmac` / `hyprctl` CLI |
| `bar/battery-details/` | OmniWM's battery widget with a Devices section (iPhone, AirPods, keyboard); installed into `~/.config/omniwm/shell/widgets/` |
| `bar/device-batteries.py` | login agent, every minute: iPhone battery over Wi-Fi via libimobiledevice → `omniwmctl shell set hyprmac_devices` |
| `config/hyprland.conf` | the default config, shaped after Hunter's AeroSpace keys |
| `install.sh`, `uninstall.sh` | install and remove everything, including the login agents |

## Rules

- Build with `app/build.sh OUTDIR`. It produces an ad-hoc signed app, so every rebuild changes the
  code hash and macOS drops the Accessibility grant. The installer rebuilds only when
  `app/Sources/*.swift` or `Info.plist` change; keep it that way.
- Test in the hidden Mac (`ssh mini hidden-mac <job> ...`), never on Hunter's own screen. The test
  helpers (key and mouse sender, TCC grant script) live in the session scratch folder, not in this repo.
  Never run `osascript` against System Events there: it hangs on a hidden permission prompt.
- OmniWM's `settings.toml` uses a strict schema. Only set keys that exist in OmniWM's defaults, and keep
  its own hotkeys off (`hotkeysEnabled = false`) so the two don't fight over keys.
- `omniwmctl` frames use a bottom-left origin (Cocoa coordinates), so in its output a larger `y` is
  higher on the screen.
- The phone job may only query phones macOS already trusts (it checks usbmuxd for a pairing record
  first); never let it start pairing, which pops a "Trust This Computer?" prompt on the phone.
- No GitHub Actions on macOS runners and no schedules (`cc-actions-guard .` before pushing).
