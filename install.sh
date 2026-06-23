#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_APP="${ROOT_DIR}/build/DerivedData/Build/Products/Release/MountJockey.app"
INSTALL_DIR="${HOME}/Applications"
INSTALL_APP="${INSTALL_DIR}/MountJockey.app"

if [[ ! -d "${SOURCE_APP}" ]]; then
  "${ROOT_DIR}/scripts/build-release.sh"
fi

mkdir -p "${INSTALL_DIR}"
rm -rf "${INSTALL_APP}"
ditto "${SOURCE_APP}" "${INSTALL_APP}"
xattr -dr com.apple.quarantine "${INSTALL_APP}" 2>/dev/null || true

open "${INSTALL_APP}"
echo "Installed MountJockey at ${INSTALL_APP}"
echo "Enable 'Launch MountJockey at login' in Preferences after opening the app."
