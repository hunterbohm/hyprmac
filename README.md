# HyprMac

Hyprland's feel on a Mac: tiling with gaps, animations, gradient borders, and Hyprland shortcuts, set up
from a `hyprland.conf` in Hyprland's own syntax. Your normal Mac apps keep working.

macOS can't run Hyprland itself. HyprMac has two parts:

- **[OmniWM](https://github.com/BarutSRB/OmniWM)** does the tiling. It has a dwindle layout (Hyprland's
  default), a scrolling layout, animations and borders.
- **The HyprMac agent** reads `~/.config/hyprmac/hyprland.conf`. It catches your shortcuts and carries out
  each Hyprland dispatcher through OmniWM. It also writes your look-and-feel settings (gaps, borders,
  animations, layout, mouse binds and workspaces) into OmniWM's settings.

Needs an Apple Silicon Mac with macOS 26 or later, Homebrew, and the Xcode Command Line Tools.

## Install

```sh
./install.sh
```

The installer:

- installs OmniWM, and Ghostty if it's missing;
- builds the agent into `~/Applications/HyprMac.app`;
- adds `hyprmac` and `hyprctl` to `~/.local/bin`;
- copies the default config, unless you already have one;
- starts everything at login.

macOS then asks for two permissions in System Settings → Privacy & Security:

- **Accessibility**: turn on OmniWM and HyprMac.
- **Input Monitoring**: turn on OmniWM.

OmniWM also shows its own permission window the first time. Screen Recording is optional there and
gives overview its window previews. Press Continue, and HyprMac applies its settings by itself. The
installer waits until both are on. Running it again is safe: it rebuilds only when the source
changed, so macOS keeps HyprMac's permission.

Quit AeroSpace or yabai first, because two tiling managers fight over the same windows.

To undo everything, run `./uninstall.sh`. It keeps your config; `--purge` deletes it as well, and
`--remove-omniwm` also uninstalls OmniWM.

## Keys

SUPER is your **Option (⌥)** key, which sits where Super does on a PC keyboard. ALT is Command (⌘), and
CTRL is Control. You can also name a Mac key directly with `OPTION`, `COMMAND`, `CONTROL` or `HYPER`
(all four held). To make SUPER a different key, set `super_key` inside `hyprmac { }`.

| Keys | Does |
|---|---|
| ⌥ Return | new Ghostty window |
| ⌥ ⇧ Return / ⌥ E | browser / new Finder window |
| ⌥ B C T O D | jump to Helium, Codex, Ghostty, Obsidian, Vesktop (opens the app if it has no window) |
| ⌥ H J K L | move focus |
| ⌥ ⇧ H J K L | move the window |
| ⌥ ⌃ H J K L | move the window into a stack |
| ⌥ 1–9, 0 | go to workspace 1–10 (⌃ 1–0 too) |
| ⌥ ⇧ 1–9, 0 | send the window to that workspace and go with it |
| ⌥ A / ⌥ S | the right / left workspace on a second screen |
| ⌥ Tab, ⌥ scroll | previous workspace, next or previous workspace |
| ⌥ W | close the window |
| ⌥ F | fullscreen |
| ⌥ ⇧ F | reading mode: float the window as a centered column; again to tile it |
| ⌥ V | float or tile |
| ⌥ / | flip the split |
| ⌥ , | even out the sizes |
| ⌥ − / ⌥ = | narrower / wider (add ⇧ for height) |
| ⌥ R | resize mode: H J K L, B to even out, Esc to leave |
| ⌥ Z / ⌥ ⇧ Z | show or hide the scratchpad / send the window there |
| ⌥ ⇧ / | switch this workspace between dwindle and scrolling |
| ⌥ ⇧ O | overview |
| ⌥ ` | drop-down terminal |
| ⌃ ⌥ Space | command palette |
| ⌥ + left drag / right drag | move / resize a window |
| ⌃ ⌥ J K, ⌃ ⌥ ⇧ J K | focus the next screen, send the window to the next screen |
| Hyper R | record mode: tile everything inside a centered 2134×1200 stage, border off; again to stop |
| Hyper P | prompter: float the focused window (an Obsidian note) in the margin right of the stage |
| Hyper L | your theme switch |

Hyper is ⌘⌃⌥⇧ held together. Record mode and the prompter end when the agent restarts.

`hyprctl binds` lists every key in your config.

Gaps: 10 points when another screen is connected, none on the MacBook screen alone
(`laptop_gaps = false` in `hyprmac { }`). A lone window keeps its gaps, as in Hyprland.

## Config

Edit `~/.config/hyprmac/hyprland.conf`. Saving applies it at once, as in Hyprland. If a line has a
mistake, a red bar at the top of the screen shows the line number and what's wrong.

Supported Hyprland syntax:

- `$variables`, `source = file`, `exec-once`, `exec`.
- `bind` with the `l r e n m t i d s o` flags: `binde` repeats while held, `bindm` binds the mouse, and
  `bindd` takes a description.
- `submap`, `unbind`, and `workspace = N, monitor:..., layout:..., name:...`.
- These sections:
  - `general`: gaps (`gaps_out` takes one value or top, right, bottom, left), borders, gradient colors,
    layout.
  - `animations`: `enabled`, plus HyprMac's `speed`.
  - `input`: `follow_mouse`.
  - `dwindle`: `split_width_multiplier`, `smart_split`, `default_split_ratio`.
- `monitor`, `windowrule`, `layerrule` and `env` lines are accepted and ignored.

Dispatchers:

- **Windows**: `exec`, `killactive`, `togglefloating`, `fullscreen`, `movefocus`, `movewindow` and
  `swapwindow` (including `mon:`), `moveintogroup`, `resizeactive`, `togglesplit`, `swapsplit`,
  `layoutmsg`, `centerwindow`, `changegroupactive`.
- **Workspaces**: `workspace` (a number, `±1`, `previous`, `name:`), `movetoworkspace`,
  `movetoworkspacesilent`, `togglespecialworkspace`.
- **Screens**: `focusmonitor`, `movecurrentworkspacetomonitor`.
- **Other**: `focuscurrentorlast`, `submap`, `dpms`.
- **HyprMac extras**:
  - `focusapp, <bundle id or app name>`
  - `layout, dwindle|scrolling|toggle`
  - `overview`
  - `balance`
  - `sendshortcut, MODS, key`
  - `readingmode [max width]`, `recordmode, WxH`, `prompter, WxH`
  - `omniwm, <any omniwmctl command>`
- **Ignored, with a note in the log** (macOS has no match): `pseudo`, `pin`, `togglegroup`, `exit`.

## Commands

```
hyprctl reload              reread the config
hyprctl dispatch DISPATCHER [ARG]
hyprctl binds               list your keys
hyprctl check [FILE]        check a config for mistakes
hyprctl status              is everything running?
```

The log is at `~/.local/state/hyprmac/hyprmac.log`.
