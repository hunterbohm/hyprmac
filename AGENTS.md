# HyprMac

This repo makes a Mac feel like Hyprland. A small Swift agent (`app/Sources`) reads
`~/.config/hyprmac/hyprland.conf`, catches bound keys with a CGEvent tap, and runs each Hyprland
dispatcher through OmniWM's `omniwmctl`. It also writes the look-and-feel settings into OmniWM's
`~/.config/omniwm/settings.toml`. The README covers user-facing behavior.

## Before you change code

- Before changing or adding a file under `app/Sources/`, `bar/` or `config/`, or `install.sh` /
  `uninstall.sh`, read that file's row in the Layout table of `docs/code-map.md`. Read it also before
  copying any OmniWM file (such as its notifications widget) into this repo: some must never be copied.
- Before changing `movewindow`, `moveDwindleWindow`, the key tap (`app/Sources/KeyTap.swift`) or how
  binds queue on `Dispatchers.omniQueue`, read "Function notes" in `docs/code-map.md`.

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
- `omniwmctl` frames use a bottom-left origin (Cocoa coordinates), so in its output a larger `y` is
  higher on the screen.
- The phone job may only query phones macOS already trusts (it checks usbmuxd for a pairing record
  first); never let it start pairing, which pops a "Trust This Computer?" prompt on the phone.
- No GitHub Actions on macOS runners and no schedules (`cc-actions-guard .` before pushing).
