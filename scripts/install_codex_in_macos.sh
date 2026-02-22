#!/bin/sh
set -eu

DMG_PATH="/Volumes/CodexTools/Codex.dmg"
ENV_PATH="/Volumes/CodexTools/ai-provider.env"
MOUNT_POINT="/Volumes/CodexInstaller"
USER_HOME="${HOME:-/Users/$(id -un)}"
CONFIG_DIR="$USER_HOME/.codex"
CONFIG_ENV="$CONFIG_DIR/ai-provider.env"

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

mkdir -p "$CONFIG_DIR"
if [ -f "$ENV_PATH" ]; then
  cp "$ENV_PATH" "$CONFIG_ENV"
fi

if [ ! -s "$CONFIG_ENV" ] || ! grep -q 'OPENAI_API_KEY=' "$CONFIG_ENV"; then
  echo "No provider config found. Create $CONFIG_ENV with OPENAI_API_KEY / ANTHROPIC_API_KEY."
fi

echo "Codex installation complete."
echo "Provider config: $CONFIG_ENV"
echo "If both OPENAI_API_KEY and ANTHROPIC_API_KEY are set, default model should be gpt-5.3-codex."
