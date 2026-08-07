#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/ShareBeacon.app"
ZIP_PATH="${BUILD_DIR}/ShareBeacon.zip"
VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "${ROOT_DIR}" rev-list --count HEAD)}}"

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]
[[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]]

rm -rf "${DERIVED_DATA}" "${ZIP_PATH}"
mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/ShareBeacon.xcodeproj" \
  -scheme ShareBeacon \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION="${VERSION}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  build

test -d "${APP_PATH}"
codesign --force --deep --sign - --options runtime "${APP_PATH}"

ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/ShareBeacon")"
[[ "${ARCHITECTURES}" == *arm64* && "${ARCHITECTURES}" == *x86_64* ]]

ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "Built ${ZIP_PATH}"
echo "Version ${VERSION} (build ${BUILD_NUMBER})"
