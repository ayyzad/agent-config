#!/usr/bin/env bash
# Builds "Agent Config.app" into build/.
#   --icon     regenerate Resources/AppIcon.icns first
#   --install  copy the app to ~/Applications
set -euo pipefail
cd "$(dirname "$0")/.."

for arg in "$@"; do
  if [ "$arg" = "--icon" ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  fi
done

swift build -c release --product AgentConfig
BIN="$(swift build -c release --show-bin-path)/AgentConfig"

APP="build/Agent Config.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentConfig"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
codesign --force --sign - "$APP"
echo "Built $APP"

for arg in "$@"; do
  if [ "$arg" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Agent Config.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/Agent Config.app"
  fi
done
