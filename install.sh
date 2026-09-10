#!/usr/bin/env bash
#
# Installs mic-lock: a per-user launchd agent with a menu-bar item that keeps
# the default audio input pinned to the device you choose.

set -euo pipefail

LABEL="com.miclock"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="$HOME/.local/share/mic-lock"
APP="$SHARE_DIR/MicLock.app"
BIN="$APP/Contents/MacOS/mic-lock"
LINK="$HOME/.local/bin/mic-lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/miclock.log"
UID_NUM="$(id -u)"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: 'swiftc' not found. Install the Xcode Command Line Tools first:" >&2
  echo "       xcode-select --install" >&2
  exit 1
fi

echo "==> Building MicLock.app"
mkdir -p "$APP/Contents/MacOS" "$(dirname "$LINK")" \
         "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$SCRIPT_DIR/main.swift" "$SHARE_DIR/main.swift"
swiftc -O -swift-version 5 "$SHARE_DIR/main.swift" -o "$BIN" \
  -framework AppKit -framework AVFoundation -framework CoreAudio -framework IOKit

# LSUIElement keeps it out of the Dock and the app switcher: menu bar only.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>          <string>$LABEL</string>
    <key>CFBundleName</key>                <string>MicLock</string>
    <key>CFBundleDisplayName</key>         <string>MicLock</string>
    <key>CFBundleExecutable</key>          <string>mic-lock</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleShortVersionString</key>  <string>2.0</string>
    <key>CFBundleVersion</key>             <string>2</string>
    <key>LSMinimumSystemVersion</key>      <string>14.4</string>
    <key>LSUIElement</key>                 <true/>
    <key>NSHighResolutionCapable</key>     <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Keeps an iPhone (Continuity) microphone session alive for a while after you use it, so the next app that needs the mic does not wait several seconds for it. Captured audio is discarded immediately and never recorded.</string>
</dict>
</plist>
EOF

# An ad-hoc signature gives the app a stable identity for the microphone
# permission. Note that rebuilding changes it, so consent is asked again.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

ln -sfn "$BIN" "$LINK"

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
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
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
echo "==> Done. Look for the microphone icon in your menu bar."
echo "    Logs:  $LOG"
echo "    Stop:  launchctl bootout gui/$UID_NUM/$LABEL"
echo "    Start: launchctl bootstrap gui/$UID_NUM $PLIST"
