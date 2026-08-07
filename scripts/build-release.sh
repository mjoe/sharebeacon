#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: ./scripts/build-release.sh [options]

Options:
  --clean                 Remove derived data before building
  --skip-sign             Leave the app unsigned
  --build-number NUMBER   Override the generated build number
  -h, --help              Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/build"
DERIVED_DATA="${BUILD_DIR}/DerivedData"
APP_PATH="${DERIVED_DATA}/Build/Products/Release/ShareBeacon.app"
VERSION="$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$(git -C "${ROOT_DIR}" rev-list --count HEAD)}}"
CLEAN=0
SIGN=1

while (($# > 0)); do
  case "$1" in
    --clean)
      CLEAN=1
      ;;
    --skip-sign)
      SIGN=0
      ;;
    --build-number)
      (($# >= 2)) || { printf '%s\n' "--build-number requires a value" >&2; exit 2; }
      BUILD_NUMBER="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || {
  printf 'Invalid VERSION: %s\n' "${VERSION}" >&2
  exit 1
}
[[ "${BUILD_NUMBER}" =~ ^[0-9]+$ ]] || {
  printf 'Invalid build number: %s\n' "${BUILD_NUMBER}" >&2
  exit 1
}

for tool in xcodebuild codesign lipo ditto; do
  xcrun --find "${tool}" >/dev/null
done

ZIP_PATH="${BUILD_DIR}/ShareBeacon-${VERSION}.zip"
CHECKSUM_PATH="${ZIP_PATH}.sha256"

if ((CLEAN)); then
  rm -rf "${DERIVED_DATA}"
fi
rm -f "${ZIP_PATH}" "${CHECKSUM_PATH}"
mkdir -p "${BUILD_DIR}"

xcrun xcodebuild \
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

if ((SIGN)); then
  xcrun codesign --force --deep --sign - --options runtime "${APP_PATH}"
  xcrun codesign --verify --deep --strict "${APP_PATH}"
else
  printf '%s\n' "Warning: leaving ShareBeacon unsigned."
fi

ARCHITECTURES="$(xcrun lipo -archs "${APP_PATH}/Contents/MacOS/ShareBeacon")"
[[ "${ARCHITECTURES}" == *arm64* && "${ARCHITECTURES}" == *x86_64* ]] || {
  printf 'Unexpected architectures: %s\n' "${ARCHITECTURES}" >&2
  exit 1
}

xcrun ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"
shasum -a 256 "${ZIP_PATH}" > "${CHECKSUM_PATH}"

printf 'Built %s\n' "${ZIP_PATH}"
printf 'Checksum %s\n' "${CHECKSUM_PATH}"
printf 'Version %s (build %s)\n' "${VERSION}" "${BUILD_NUMBER}"
