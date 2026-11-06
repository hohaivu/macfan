#!/usr/bin/env bash
# DEVELOPMENT ONLY. Installs the fan-control helper as a classic LaunchDaemon,
# bypassing SMAppService. Use it when macOS refuses to start the helper of an
# ad-hoc signed build. Release builds should use the in-app "Install Helper".
#
#   sudo scripts/install-helper-dev.sh install [path/to/MacFan.app]
#   sudo scripts/install-helper-dev.sh uninstall
set -euo pipefail

LABEL="io.github.alvinmr.MacFan.helper"
DEST="/Library/PrivilegedHelperTools/$LABEL"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
ACTION="${1:-install}"
APP="${2:-build/MacFan.app}"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

launchctl bootout "system/$LABEL" 2>/dev/null || true

case "$ACTION" in
  install)
    install -m 755 -o root -g wheel "$APP/Contents/MacOS/macfan-helper" "$DEST"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$DEST</string>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict>
</plist>
EOF
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
    launchctl bootstrap system "$PLIST"
    echo "✓ Helper installed. Reopen MacFan."
    ;;
  uninstall)
    rm -f "$DEST" "$PLIST"
    echo "✓ Helper removed. Fans are back under macOS control."
    ;;
  *)
    echo "usage: sudo $0 install|uninstall [MacFan.app]" >&2
    exit 64
    ;;
esac
