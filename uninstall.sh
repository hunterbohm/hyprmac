#!/bin/bash
# Remove HyprMac and stop the tiling. Your hyprland.conf stays unless you pass --purge.
#
#   ./uninstall.sh                 stop and remove HyprMac, put OmniWM's own settings back, quit OmniWM
#   ./uninstall.sh --purge         also delete ~/.config/hyprmac and HyprMac's logs
#   ./uninstall.sh --remove-omniwm also uninstall the OmniWM app
set -euo pipefail

APP="$HOME/Applications/HyprMac.app"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hyprmac"
STATE_DIR="$HOME/.local/state/hyprmac"
AGENTS="$HOME/Library/LaunchAgents"
LABEL="com.hunterbohm.hyprmac"
OMNI_LABEL="com.hunterbohm.hyprmac.omniwm"
DEVICES_LABEL="com.hunterbohm.hyprmac.devices"
SHARE_DIR="$HOME/.local/share/hyprmac"
WIDGET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/widgets/battery-details"
OMNI_SETTINGS="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/settings.toml"
PURGE=0 REMOVE_OMNI=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    --remove-omniwm) REMOVE_OMNI=1 ;;
    *) echo "usage: ./uninstall.sh [--purge] [--remove-omniwm]" >&2; exit 2 ;;
  esac
done
say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

uid="$(id -u)"
for label in "$LABEL" "$OMNI_LABEL" "$DEVICES_LABEL"; do
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  rm -f "$AGENTS/$label.plist"
done
pkill -f "$APP/Contents/MacOS/hyprmac" 2>/dev/null || true
say "Stopped HyprMac and removed its login items"

# The battery panel with your devices goes back to OmniWM's own (only if HyprMac put it there).
if [[ -f "$WIDGET_DIR/.hyprmac" ]]; then
  rm -rf "$WIDGET_DIR"
  say "Put OmniWM's own battery panel back"
fi
SHELL_TOML="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/shell.toml"
if [[ -f "$SHELL_TOML" ]] && grep -q '^# HyprMac bar layout' "$SHELL_TOML"; then
  rm -f "$SHELL_TOML"
  say "Put OmniWM's own bar layout back"
fi
TRAY_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omniwm/shell/widgets/tray"
[[ -f "$TRAY_DIR/.hyprmac" ]] && rm -rf "$TRAY_DIR" && say "Removed the menu bar apps tray from OmniWM's bar"
rm -rf "$SHARE_DIR"

# Put back the OmniWM settings from before HyprMac changed them (OmniWM's own shortcuts were off).
if [[ -f "$OMNI_SETTINGS.hyprmac-backup" ]]; then
  cp "$OMNI_SETTINGS" "$OMNI_SETTINGS.hyprmac-last" 2>/dev/null || true
  mv "$OMNI_SETTINGS.hyprmac-backup" "$OMNI_SETTINGS"
  say "Restored OmniWM's earlier settings (HyprMac's version saved as settings.toml.hyprmac-last)"
fi

if pgrep -x OmniWM >/dev/null; then
  osascript -e 'quit app "OmniWM"' >/dev/null 2>&1 || pkill -x OmniWM || true
  say "Quit OmniWM"
fi

for link in hyprmac hyprctl; do
  if [[ -L "$BIN_DIR/$link" && "$(readlink "$BIN_DIR/$link")" == "$APP/"* ]]; then rm -f "$BIN_DIR/$link"; fi
done
rm -rf "$APP"
rm -f "$STATE_DIR/build.sha256" "$STATE_DIR/hyprmac.pid"
say "Removed HyprMac.app and the hyprmac / hyprctl commands"

if (( PURGE )); then
  rm -rf "$CONFIG_DIR" "$STATE_DIR"
  say "Deleted your hyprland.conf and HyprMac's logs"
else
  say "Kept $CONFIG_DIR/hyprland.conf"
fi

if (( REMOVE_OMNI )); then
  BREW="$(command -v brew || echo /opt/homebrew/bin/brew)"
  "$BREW" uninstall --cask omniwm && say "Uninstalled OmniWM"
fi

if [[ -d /Applications/AeroSpace.app ]]; then
  echo "To bring AeroSpace back: open -a AeroSpace"
fi
echo "macOS keeps HyprMac's switch in Privacy & Security → Accessibility; remove it there with the minus button if you like."
