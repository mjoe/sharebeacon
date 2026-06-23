#!/usr/bin/env bash
set -Eeuo pipefail

APP_PATH="${HOME}/Applications/MountJockey.app"
BUNDLE_ID="com.valmayaki.mountjockey"

osascript -e 'tell application "MountJockey" to quit' 2>/dev/null || true
rm -rf "${APP_PATH}"

if [[ "${1:-}" == "--purge" ]]; then
  defaults delete "${BUNDLE_ID}" 2>/dev/null || true
  rm -f "${HOME}/Library/Logs/mountjockey.log" \
    "${HOME}/Library/Logs/mountjockey.log.1"
  echo "Removed MountJockey, configuration, and logs."
  echo "Keychain items remain available for manual review in Keychain Access."
else
  echo "Removed MountJockey. Configuration, logs, and Keychain credentials were preserved."
fi
