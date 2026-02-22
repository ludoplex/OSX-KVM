#!/bin/sh
set -eu

DMG_PATH="/Volumes/CodexTools/Codex.dmg"
MOUNT_POINT="/Volumes/CodexInstaller"

if [ ! -f "$DMG_PATH" ]; then
  echo "Codex.dmg not found at $DMG_PATH"
  exit 1
fi

hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT"

APP_PATH="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.app' | head -n 1)"
PKG_PATH="$(find "$MOUNT_POINT" -maxdepth 1 -name '*.pkg' | head -n 1)"

if [ -n "$APP_PATH" ]; then
  cp -R "$APP_PATH" /Applications/
  echo "Installed app: $(basename "$APP_PATH")"
elif [ -n "$PKG_PATH" ]; then
  sudo installer -pkg "$PKG_PATH" -target /
  echo "Installed package: $(basename "$PKG_PATH")"
else
  echo "No .app or .pkg found in Codex.dmg"
  hdiutil detach "$MOUNT_POINT"
  exit 1
fi

hdiutil detach "$MOUNT_POINT"
echo "Codex installation complete."
