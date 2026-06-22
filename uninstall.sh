#!/usr/bin/env bash
#
# Removes mic-lock and its launchd agent.

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

echo "==> mic-lock removed."
