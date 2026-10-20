#!/bin/bash
# Installs the latest Dial release into /Applications.
#   curl -fsSL https://raw.githubusercontent.com/Sskskxi/dial/main/install.sh | bash
set -euo pipefail

URL="https://github.com/Sskskxi/dial/releases/latest/download/Dial.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$(uname -m)" != "arm64" ]; then
  echo "Dial needs a Mac with Apple silicon (M1 or later)." >&2
  exit 1
fi

echo "Downloading Dial…"
curl -fL --progress-bar "$URL" -o "$TMP/Dial.zip"
ditto -x -k "$TMP/Dial.zip" "$TMP"

echo "Installing to /Applications…"
pkill -x Dial 2>/dev/null || true
rm -rf /Applications/Dial.app
ditto "$TMP/Dial.app" /Applications/Dial.app
# Dial isn't notarized, so clear the download flag that makes Gatekeeper block it.
xattr -dr com.apple.quarantine /Applications/Dial.app 2>/dev/null || true

if command -v brew >/dev/null 2>&1; then
  echo "Installing ffmpeg and webp (for video, audio and WebP)…"
  brew install ffmpeg webp
else
  echo "Note: install Homebrew (https://brew.sh), then run: brew install ffmpeg webp"
  echo "      Images, PDFs, documents and archives work without them."
fi

open /Applications/Dial.app
echo "Done. Look for the dial icon in your menu bar."
