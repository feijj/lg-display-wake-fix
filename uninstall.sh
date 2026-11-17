#!/bin/zsh
# Stops and removes the lgwakefix agent and its installed files.
set -euo pipefail

label="local.lgwakefix"
system_plist="/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -rf /Users/Shared/lgwakefix
if [[ -e "$system_plist" ]]; then
  sudo rm -f "$system_plist"   # only present after ./install.sh --persist
fi
echo "removed $label (log left at $HOME/Library/Logs/lgwakefix.log)"
