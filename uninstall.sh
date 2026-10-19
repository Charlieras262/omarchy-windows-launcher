#!/bin/bash
# Remove everything install.sh added and restore the stock launcher entry.
set -euo pipefail

PLUGIN_ID=charlieras262.windows-launcher
DATA="$HOME/.local/share/omarchy-windows-launcher"
DESKTOP="$HOME/.local/share/applications/windows-vm.desktop"
BACKUP="$DATA/windows-vm.desktop.stock"

if [[ -f $BACKUP ]]; then
  cp "$BACKUP" "$DESKTOP"
elif grep -q omarchy-windows-launcher "$DESKTOP" 2>/dev/null; then
  # Stock content written by `omarchy windows vm install`.
  cat >"$DESKTOP" <<ENTRY
[Desktop Entry]
Name=Windows
Comment=Start Windows VM via Docker and connect with RDP
Exec=uwsm app -- omarchy-windows-vm launch
Icon=windows
Terminal=false
Type=Application
Categories=System;Virtualization;
ENTRY
fi

rm -f "$HOME/.local/bin/omarchy-windows-launcher"
rm -rf "$HOME/.config/omarchy/plugins/$PLUGIN_ID" "$DATA"
omarchy-shell -q shell rescanPlugins || true
echo "Uninstalled; the stock Windows entry is back."
