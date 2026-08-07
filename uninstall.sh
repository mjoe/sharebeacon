#!/usr/bin/env bash
set -Eeuo pipefail

APP_PATH="${HOME}/Applications/ShareBeacon.app"
BUNDLE_ID="com.mjoe.sharebeacon"

osascript -e 'tell application "ShareBeacon" to quit' 2>/dev/null || true
rm -rf "${APP_PATH}"

if [[ "${1:-}" == "--purge" ]]; then
  defaults delete "${BUNDLE_ID}" 2>/dev/null || true
  rm -f "${HOME}/Library/Logs/sharebeacon.log" \
    "${HOME}/Library/Logs/sharebeacon.log.1"
  echo "Removed ShareBeacon, configuration, and logs."
  echo "Keychain items remain available for manual review in Keychain Access."
else
  echo "Removed ShareBeacon. Configuration, logs, and Keychain credentials were preserved."
fi
