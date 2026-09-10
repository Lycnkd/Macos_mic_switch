#!/usr/bin/env bash
#
# Removes mic-lock, its launchd agent and its preferences.

set -euo pipefail

LABEL="com.miclock"
UID_NUM="$(id -u)"

echo "==> Stopping agent"
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true

echo "==> Removing files"
rm -f "$HOME/.local/bin/mic-lock" \
      "$HOME/Library/LaunchAgents/$LABEL.plist" \
      "$HOME/Library/Logs/miclock.log"
rm -rf "$HOME/.local/share/mic-lock"

echo "==> Removing preferences"
defaults delete "$LABEL" 2>/dev/null || true

echo "==> mic-lock removed."
echo "    Its microphone permission entry stays in System Settings > Privacy &"
echo "    Security > Microphone; remove it there if you want it gone."
