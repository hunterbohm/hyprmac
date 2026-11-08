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

- installs OmniWM, Ghostty if it's missing, and libimobiledevice (it reads your iPhone's battery);
- builds the agent into `~/Applications/HyprMac.app`;
- adds `hyprmac` and `hyprctl` to `~/.local/bin`;
- copies the default config, unless you already have one;
- puts HyprMac's battery panel and menu bar apps tray in OmniWM's bar;
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

## Bar

OmniWM draws the bar. Click its battery for HyprMac's battery panel: the Mac's battery, then your
devices, as in Apple's Batteries widget.

- **iPhone and iPad**: read over Wi-Fi once a minute. The phone needs to sync with this Mac over Wi-Fi
  (Finder → your iPhone → "Show this iPhone when on Wi-Fi") and be on the same network. A sleeping phone
  drops off Wi-Fi now and then, so the panel keeps the last reading and says how old it is.
- **AirPods, keyboard, mouse**: Bluetooth devices that are connected and report a battery. AirPods show
  left, right and case. The first time, the panel has a button to give OmniWM Bluetooth access.

**Menu bar apps** (Tailscale, CleanShot, Bitwarden and so on) sit in OmniWM's bar next to the volume and
Wi-Fi, like Waybar's tray. OmniWM's bar covers the macOS menu bar, so HyprMac finds each app's menu bar
item, shows the app's icon in the bar, and opens the app's real menu when you click it. The menu opens
where the app's hidden menu bar item sits, on the right side of the screen.
- Leave an app out with `tray_hide = Google Drive, Another App` in `hyprmac { }` (app names or bundle IDs).
- Quit menu bar hiders such as Thaw, Ice or Bartender: the bar shows every item itself.
- Workspaces with no windows don't show in the bar, which leaves room for the tray on a MacBook.

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
