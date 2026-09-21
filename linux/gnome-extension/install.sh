#!/usr/bin/env bash
# Installs the overlay extension for the current user, no root needed.
set -euo pipefail
DEST="${HOME}/.local/share/gnome-shell/extensions/veil@veil.dev"
mkdir -p "$DEST"
cp -f metadata.json extension.js stylesheet.css "$DEST/"
echo "installed to $DEST"
echo
echo "On Wayland the shell cannot be restarted in place, so log out and back in,"
echo "then: gnome-extensions enable veil@veil.dev"
