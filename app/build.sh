#!/bin/bash
# Build HyprMac.app. usage: app/build.sh [output-dir]   (default: build/)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../build}"
mkdir -p "$out"
app="$out/HyprMac.app"
rm -rf "$app.tmp"
mkdir -p "$app.tmp/Contents/MacOS" "$app.tmp/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework ApplicationServices \
  -o "$app.tmp/Contents/MacOS/hyprmac" "$here"/Sources/*.swift
cp "$here/Info.plist" "$app.tmp/Contents/Info.plist"
"$here/sign.sh" "$app.tmp" com.hunterbohm.hyprmac >/dev/null
rm -rf "$app"
mv "$app.tmp" "$app"
echo "$app"
