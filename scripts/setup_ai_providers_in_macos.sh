#!/bin/sh
set -eu

SRC="/Volumes/CodexTools/ai-model-providers.env"
DEST="$HOME/.codex-ai-providers.env"

if [ ! -f "$SRC" ]; then
  echo "No ai-model-providers.env found on CodexTools media."
  echo "Re-run one-click setup and complete the setup wizard on host."
  exit 1
fi

cp "$SRC" "$DEST"
chmod 600 "$DEST"

echo "Provider config installed to: $DEST"
echo "Load it in current shell with: source $DEST"
echo "If both tokens are present, Codex (GPT-5.3 Codex) is set as default provider."
