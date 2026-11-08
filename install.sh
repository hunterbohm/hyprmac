#!/bin/bash
# HyprMac installer: OmniWM (the tiling window manager) + the HyprMac agent that reads hyprland.conf.
# Safe to run again; it rebuilds the agent only when its source changed and never overwrites your config.
#
#   ./install.sh            install or update
#   ./install.sh --no-start install files but leave the agent and OmniWM stopped
#   ./install.sh --no-wait  start everything but don't wait for the permission switches
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/HyprMac.app"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hyprmac"
STATE_DIR="$HOME/.local/state/hyprmac"
AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.hunterbohm.hyprmac"
OMNI_LABEL="com.hunterbohm.hyprmac.omniwm"
DEVICES_LABEL="com.hunterbohm.hyprmac.devices"
SHARE_DIR="$HOME/.local/share/hyprmac"
OMNI_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/settings.toml"
START=1 WAIT=1
for arg in "$@"; do
  case "$arg" in
    --no-start) START=0 ;;
    --no-wait) WAIT=0 ;;
    *) echo "usage: ./install.sh [--no-start] [--no-wait]" >&2; exit 2 ;;
  esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---- requirements
[[ "$(uname)" == Darwin ]] || die "HyprMac runs on macOS"
[[ "$(uname -m)" == arm64 ]] || die "OmniWM needs an Apple Silicon Mac"
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 26 )) || die "OmniWM needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))"
xcrun --find swiftc >/dev/null 2>&1 || die "Xcode Command Line Tools are missing: run 'xcode-select --install', then this again"
BREW="$(command -v brew || true)"
[[ -z "$BREW" && -x /opt/homebrew/bin/brew ]] && BREW=/opt/homebrew/bin/brew
[[ -n "$BREW" ]] || die "Homebrew is missing: install it from https://brew.sh, then run this again"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ENV_HINTS=1

# ---- OmniWM
if [[ ! -d /Applications/OmniWM.app ]]; then
  say "Installing OmniWM"
  "$BREW" install --cask omniwm
fi
# Homebrew downloads carry the quarantine flag, which shows a "downloaded from the Internet" prompt.
xattr -dr com.apple.quarantine /Applications/OmniWM.app 2>/dev/null || true
if [[ ! -d /Applications/Ghostty.app ]] && ! "$BREW" list --cask ghostty >/dev/null 2>&1; then
  say "Installing Ghostty (the terminal on Super+Return)"
  "$BREW" install --cask ghostty
  xattr -dr com.apple.quarantine /Applications/Ghostty.app 2>/dev/null || true
fi

# ---- build the agent (only when the source changed, so macOS keeps its Accessibility permission)
mkdir -p "$APP_DIR" "$BIN_DIR" "$STATE_DIR" "$AGENTS"
src_hash="$(cat "$REPO"/app/Sources/*.swift "$REPO"/app/Info.plist | shasum -a 256 | cut -d' ' -f1)"
stamp="$STATE_DIR/build.sha256"
if [[ ! -x "$APP/Contents/MacOS/hyprmac" || "$(cat "$stamp" 2>/dev/null)" != "$src_hash" ]]; then
  say "Building HyprMac"
  build_dir="$(mktemp -d)"
  "$REPO/app/build.sh" "$build_dir" >/dev/null
  rm -rf "$APP"
  mv "$build_dir/HyprMac.app" "$APP"
  rm -rf "$build_dir"
  echo "$src_hash" > "$stamp"
  REBUILT=1
else
  REBUILT=0
fi
ln -sf "$APP/Contents/MacOS/hyprmac" "$BIN_DIR/hyprmac"
ln -sf "$APP/Contents/MacOS/hyprmac" "$BIN_DIR/hyprctl"

# ---- config (yours is never overwritten)
mkdir -p "$CONFIG_DIR"
if [[ ! -f "$CONFIG_DIR/hyprland.conf" ]]; then
  cp "$REPO/config/hyprland.conf" "$CONFIG_DIR/hyprland.conf"
  say "Wrote $CONFIG_DIR/hyprland.conf"
else
  say "Keeping your $CONFIG_DIR/hyprland.conf"
fi
if ! "$BIN_DIR/hyprmac" check >/dev/null; then
  warn "Your hyprland.conf has errors; HyprMac will show them in a red bar:"
  "$BIN_DIR/hyprmac" check || true
fi

# ---- OmniWM needs to have written its settings once before HyprMac can adjust them
if [[ ! -f "$OMNI_SETTINGS" ]]; then
  say "Starting OmniWM once to create its settings"
  open -a OmniWM
  for _ in $(seq 1 60); do [[ -f "$OMNI_SETTINGS" ]] && break; sleep 1; done
  [[ -f "$OMNI_SETTINGS" ]] || warn "OmniWM is waiting on its permission window; finish it there and HyprMac applies its settings on its own"
fi
[[ -f "$OMNI_SETTINGS" ]] && "$BIN_DIR/hyprmac" apply >/dev/null || true

# ---- bar: the battery panel also lists your iPhone (read over Wi-Fi) and Bluetooth devices
WIDGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/widgets/battery-details"
if [[ -d "$WIDGET_DIR" && ! -f "$WIDGET_DIR/.hyprmac" ]]; then
  warn "Keeping your own battery-details widget in $WIDGET_DIR (HyprMac's adds your iPhone and AirPods)"
else
  mkdir -p "$WIDGET_DIR"
  cp "$REPO/bar/battery-details/init.luau" "$REPO/bar/battery-details/settings.toml" "$WIDGET_DIR/"
  touch "$WIDGET_DIR/.hyprmac"
fi
# Tray: your menu bar apps inside OmniWM's bar (HyprMac supplies the list and the clicks).
TRAY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/widgets/tray"
rm -rf "$TRAY_DIR/icons"; mkdir -p "$TRAY_DIR"
cp "$REPO/bar/tray/init.luau" "$TRAY_DIR/"
touch "$TRAY_DIR/.hyprmac"
# Let macOS know HyprMac opens hyprmac:// links (the tray's clicks).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true
# Bar layout: the tray next to the volume and Wi-Fi.
SHELL_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/shell.toml"
if [[ ! -f "$SHELL_TOML" ]] || grep -q '^# HyprMac bar layout' "$SHELL_TOML"; then
  cp "$REPO/bar/shell.toml" "$SHELL_TOML"
else
  warn "Keeping your own $SHELL_TOML (HyprMac's layout is in bar/shell.toml)"
fi
"$BREW" list --formula libimobiledevice >/dev/null 2>&1 || "$BREW" install libimobiledevice >/dev/null
mkdir -p "$SHARE_DIR"
cp "$REPO/bar/device-batteries.py" "$SHARE_DIR/device-batteries.py"

# ---- login agents
cat > "$AGENTS/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/hyprmac</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$STATE_DIR/agent.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/agent.err.log</string>
</dict>
</plist>
PLIST
cat > "$AGENTS/$OMNI_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$OMNI_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/open</string><string>-g</string><string>-a</string><string>OmniWM</string></array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST
cat > "$AGENTS/$DEVICES_LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$DEVICES_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/python3</string><string>-I</string><string>$SHARE_DIR/device-batteries.py</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>ProcessType</key><string>Background</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/device-batteries.err.log</string>
</dict>
</plist>
PLIST

if (( START == 0 )); then
  say "Installed (not started). Start with: launchctl bootstrap gui/$(id -u) $AGENTS/$LABEL.plist"
  exit 0
fi

# ---- another tiling manager would fight OmniWM over the same windows
if pgrep -x AeroSpace >/dev/null; then
  warn "AeroSpace is running. Two tiling managers fight over windows; quit it with: osascript -e 'quit app \"AeroSpace\"'"
fi
for hider in Thaw Ice Bartender\ 5 Bartender\ 6; do
  if pgrep -x "$hider" >/dev/null; then
    warn "$hider is running. OmniWM's bar now shows every menu bar app itself; quit $hider so it stops moving them: osascript -e 'quit app \"$hider\"'"
  fi
done
if pgrep -x yabai >/dev/null; then
  warn "yabai is running. Stop it before using OmniWM: yabai --stop-service"
fi

uid="$(id -u)"
log_start=1
[[ -f "$STATE_DIR/hyprmac.log" ]] && log_start=$(( $(wc -l < "$STATE_DIR/hyprmac.log") + 1 ))
# Restart a login agent. Right after bootout, launchd can refuse the bootstrap for a moment
# ("Bootstrap failed: 5"), so wait for the old one to go and retry.
load_agent() {
  launchctl bootout "gui/$uid/$1" 2>/dev/null || true
  for _ in $(seq 1 10); do launchctl print "gui/$uid/$1" >/dev/null 2>&1 || break; sleep 0.5; done
  for _ in $(seq 1 10); do launchctl bootstrap "gui/$uid" "$AGENTS/$1.plist" 2>/dev/null && return 0; sleep 1; done
  warn "Could not start $1; run: launchctl bootstrap gui/$uid $AGENTS/$1.plist"
}
load_agent "$OMNI_LABEL"
pgrep -x OmniWM >/dev/null || open -g -a OmniWM
load_agent "$LABEL"
load_agent "$DEVICES_LABEL"

# ---- permissions
say "Waiting for permissions (System Settings → Privacy & Security)"
echo "    • Accessibility: turn on OmniWM and HyprMac"
echo "    • Input Monitoring: turn on OmniWM"
echo "    • Screen Recording (optional): turn on OmniWM for window previews in overview"
echo "    Then press Continue in OmniWM's own permission window."
(( REBUILT == 1 )) && echo "    (HyprMac was rebuilt, so macOS may ask for its Accessibility switch again)"
ok_agent=0 ok_omni=0
for _ in $(seq 1 $(( WAIT ? 180 : 3 ))); do
  tail -n "+$log_start" "$STATE_DIR/hyprmac.log" 2>/dev/null | grep -q "key tap installed" && ok_agent=1
  "$BIN_DIR/hyprmac" status 2>/dev/null | grep -q "OmniWM: answering" && ok_omni=1
  (( ok_agent && ok_omni )) && break
  sleep 1
done
(( ok_omni )) && say "OmniWM is running" || warn "OmniWM is not answering yet: open it and finish its permission screen"
(( ok_agent )) && say "HyprMac is reading your keys" || warn "HyprMac is waiting for Accessibility: System Settings → Privacy & Security → Accessibility → HyprMac"

cat <<'DONE'

Done. Super is your Option (⌥) key.
  ⌥ Return     terminal            ⌥ W        close window
  ⌥ H J K L    focus               ⌥ ⇧ HJKL   move window
  ⌥ 1-9, 0     workspace           ⌥ ⇧ 1-9    send window to workspace
  ⌥ F          fullscreen          ⌥ V        float / tile
  ⌥ /          flip split          ⌥ R        resize mode (HJKL, Esc)
  ⌥ ⇧ F        reading column      ⌥ E        Finder window
  Hyper R      record stage        Hyper P    prompter beside the stage
Edit ~/.config/hyprmac/hyprland.conf; saving applies it. `hyprctl binds` lists every key.
DONE
