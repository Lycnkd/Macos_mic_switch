#!/usr/bin/env bash
#
# Installs mic-lock: a per-user launchd agent that keeps the default audio
# input pinned to the Mac's built-in microphone.

set -euo pipefail

LABEL="com.miclock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin/mic-lock"
SRC_DIR="$HOME/.local/share/mic-lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/miclock.log"
UID_NUM="$(id -u)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 'swiftc' not found. Install the Xcode Command Line Tools first:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

echo "==> Compiling mic-lock"
mkdir -p "$(dirname "$BIN")" "$SRC_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$SCRIPT_DIR/main.swift" "$SRC_DIR/main.swift"
swiftc -O "$SRC_DIR/main.swift" -o "$BIN" -framework CoreAudio

echo "==> Writing launchd agent: $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
    <key>StandardOutPath</key>
    <string>$LOG</string>
</dict>
</plist>
EOF

echo "==> Loading agent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"

echo
echo "==> Done. Your default input is now pinned to the built-in mic."
echo "    Logs:  $LOG"
echo "    Stop:  launchctl bootout gui/$UID_NUM/$LABEL"
echo "    Start: launchctl bootstrap gui/$UID_NUM $PLIST"
