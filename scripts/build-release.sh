#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/MountJockey.app"
ZIP_PATH="${BUILD_DIR}/MountJockey.zip"

rm -rf "${DERIVED_DATA}" "${ZIP_PATH}"
mkdir -p "${BUILD_DIR}"

xcodebuild \
  -project "${ROOT_DIR}/jockey.xcodeproj" \
  -scheme jockey \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

test -d "${APP_PATH}"
codesign --force --deep --sign - --options runtime "${APP_PATH}"

ARCHITECTURES="$(lipo -archs "${APP_PATH}/Contents/MacOS/MountJockey")"
[[ "${ARCHITECTURES}" == *arm64* && "${ARCHITECTURES}" == *x86_64* ]]

ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
echo "Built ${ZIP_PATH}"
