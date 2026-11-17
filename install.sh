#!/bin/zsh
# Builds lgwakefix and runs it as a background agent that re-initialises the LG
# display after every wake. Re-run after editing lgwakefix.swift. Undo with uninstall.sh.
#
#   ./install.sh            run it for the current login session only (no password)
#   ./install.sh --persist  also start it at every login (asks for your password once)
#
# Everything is installed under /Users/Shared rather than ~/Library/LaunchAgents:
# when the home folder is on a volume with ownership disabled (typical for an
# external drive), launchd refuses to load agent plists from it.
set -euo pipefail

here="${0:A:h}"
label="local.lgwakefix"
dest="/Users/Shared/lgwakefix"
plist="$dest/$label.plist"
system_plist="/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

# Xcode's compiler refuses to run until its licence is accepted; the Command Line Tools one works.
if [[ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ]]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

mkdir -p "$here/build" "$dest"
swiftc -O -swift-version 5 "$here/lgwakefix.swift" -o "$here/build/lgwakefix"

launchctl bootout "$domain/$label" 2>/dev/null || true
cp "$here/build/lgwakefix" "$dest/lgwakefix"

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$dest/lgwakefix</string>
    <string>daemon</string>
    <string>--method</string><string>refresh</string>
    <string>--delay</string><string>4</string>
    <string>--hold</string><string>2</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
chmod 644 "$plist"

if [[ "${1:-}" == "--persist" ]]; then
  sudo install -o root -g wheel -m 644 "$plist" "$system_plist"
  launchctl bootstrap "$domain" "$system_plist"
  echo "installed for every login: $system_plist"
else
  launchctl bootstrap "$domain" "$plist"
  echo "running until you log out or restart; use --persist to start it at every login"
fi
echo "binary: $dest/lgwakefix"
echo "log:    $HOME/Library/Logs/lgwakefix.log"
