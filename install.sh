#!/bin/bash
# Install the Windows launcher for the current user. Idempotent; touches only
# user-owned files (constitution II). Undo with ./uninstall.sh.
#
#   ~/.local/share/omarchy-windows-launcher/   copy of bin/ lib/ (so the repo can move)
#   ~/.local/bin/omarchy-windows-launcher      symlink to the copy
#   ~/.config/omarchy/plugins/<plugin id>/     the shell plugin
#   ~/.local/share/applications/windows-vm.desktop   re-pointed at the launcher
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
PLUGIN_ID=charlieras262.windows-launcher
DATA="$HOME/.local/share/omarchy-windows-launcher"
PLUGINS="$HOME/.config/omarchy/plugins"
DESKTOP="$HOME/.local/share/applications/windows-vm.desktop"
BACKUP="$DATA/windows-vm.desktop.stock"

for cmd in jq flock xfreerdp3 omarchy-windows-vm omarchy-shell; do
  command -v "$cmd" >/dev/null || { echo "missing: $cmd" >&2; exit 1; }
done

mkdir -p "$DATA" "$HOME/.local/bin" "$PLUGINS" "$(dirname "$DESKTOP")"

rm -rf "$DATA/bin" "$DATA/lib"
cp -r "$SRC/bin" "$SRC/lib" "$DATA/"
ln -sfn "$DATA/bin/omarchy-windows-launcher" "$HOME/.local/bin/omarchy-windows-launcher"

rm -rf "${PLUGINS:?}/$PLUGIN_ID"
cp -r "$SRC/plugin" "$PLUGINS/$PLUGIN_ID"

# Remember what the existing entry ran (a user wrapper or the stock command) so
# the launcher keeps using it. Skip if the entry is already ours.
if [[ -f $DESKTOP ]] && ! grep -q omarchy-windows-launcher "$DESKTOP"; then
  prev=$(sed -n 's/^Exec=//p' "$DESKTOP" | head -n1)
  prev=${prev#uwsm app -- }
  case "$prev" in
  "omarchy-windows-vm launch" | "") rm -f "$DATA/launch-cmd" ;;
  *) printf '%s\n' "$prev" >"$DATA/launch-cmd" ;;
  esac
fi

# Keep the stock entry once so uninstall can restore it exactly.
if [[ -f $DESKTOP && ! -f $BACKUP ]] && ! grep -q omarchy-windows-launcher "$DESKTOP"; then
  cp "$DESKTOP" "$BACKUP"
fi
cat >"$DESKTOP" <<ENTRY
[Desktop Entry]
Name=Windows
Comment=Start the Windows VM (options dialog, progress windows)
Exec=uwsm app -- $HOME/.local/bin/omarchy-windows-launcher
Icon=windows
Terminal=false
Type=Application
Categories=System;Virtualization;
ENTRY

omarchy-shell -q shell rescanPlugins || true
echo "Installed. Enable the plugin if the shell does not load it:"
echo "  omarchy plugin --help"
echo "Open Windows from the launcher (Super + Space)."
