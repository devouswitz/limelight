#!/bin/zsh
# Builds Limelight.app. Pass --install to copy it to ~/Applications and relaunch it.
# Build output lives outside the project because Desktop/Documents sync adds file attributes codesign rejects.
set -euo pipefail
cd "$(dirname "$0")/.."
scratch="$HOME/Library/Caches/Limelight-build"

swift build -c release --product Limelight --scratch-path "$scratch"
[[ -f Resources/AppIcon.icns ]] || swift scripts/make-icon.swift

app="$scratch/Limelight.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$scratch/release/Limelight" "$app/Contents/MacOS/Limelight"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - --options runtime "$app"
echo "built $app"

if [[ "${1:-}" == "--install" ]]; then
  dest="$HOME/Applications/Limelight.app"
  pkill -x Limelight 2>/dev/null && sleep 0.5 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$dest"
  cp -R "$app" "$dest"
  open "$dest"
  echo "installed $dest"
fi
