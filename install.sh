#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="${ROOT_DIR}/build/DerivedData/Build/Products/Release/ShareBeacon.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/ShareBeacon.app"

if [[ ! -d "${SOURCE_APP}" ]]; then
  "${ROOT_DIR}/scripts/build-release.sh"
fi

mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_APP}"
ditto "${SOURCE_APP}" "${INSTALL_APP}"
xattr -dr com.apple.quarantine "${INSTALL_APP}" 2>/dev/null || true

open "${INSTALL_APP}"
echo "Installed ShareBeacon at ${INSTALL_APP}"
echo "Enable 'Launch ShareBeacon at login' in Preferences after opening the app."
