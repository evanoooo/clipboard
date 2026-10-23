#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
APP_DIR="${2:-}"
DIST_DIR="${3:-dist}"

if [ -z "$VERSION" ] || [ -z "$APP_DIR" ]; then
  echo "Usage: $0 <version> <app_dir> [dist_dir]"
  exit 1
fi

mkdir -p "$DIST_DIR"
DIST_DIR="$(cd "$DIST_DIR" && pwd)"
APP_DIR="$(cd "$APP_DIR" && pwd)"
WORK_DIR=$(mktemp -d /tmp/pkg_release.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

UNIVERSAL_APP="${APP_DIR}/Clipboard.app"
ARM64_APP="${WORK_DIR}/Clipboard-arm64.app"
X86_APP="${WORK_DIR}/Clipboard-x86_64.app"

echo "==> Preparing architecture variants..."
cp -R "$UNIVERSAL_APP" "$ARM64_APP"
cp -R "$UNIVERSAL_APP" "$X86_APP"

thin_app() {
  local target_arch="$1"
  local app_bundle="$2"
  find "$app_bundle" -type f -perm +111 | while read -r bin; do
    if lipo -info "$bin" 2>/dev/null | grep -q "Architectures in the fat file.*$target_arch"; then
      lipo "$bin" -thin "$target_arch" -output "$bin.tmp" && mv "$bin.tmp" "$bin"
    fi
  done
}

thin_app "arm64" "$ARM64_APP"
thin_app "x86_64" "$X86_APP"

make_dmg() {
  local app_path="$1"
  local dmg_out="$2"
  local temp_dir="${WORK_DIR}/dmg_$(basename "$dmg_out")"
  mkdir -p "$temp_dir"
  cp -R "$app_path" "$temp_dir/Clipboard.app"
  ln -s /Applications "$temp_dir/Applications"
  hdiutil create -volname "Clipboard" -srcfolder "$temp_dir" -ov -format UDZO "$dmg_out" >/dev/null
  rm -rf "$temp_dir"
}

make_zip() {
  local app_path="$1"
  local zip_out="$2"
  local app_parent
  app_parent=$(dirname "$app_path")
  (cd "$app_parent" && ditto -c -k --keepParent "Clipboard.app" "$zip_out")
}

# Rename for ditto so the unzipped app is always named Clipboard.app
mv "$ARM64_APP" "${WORK_DIR}/arm64" && mkdir -p "${WORK_DIR}/arm64" && mv "${WORK_DIR}/arm64" "${WORK_DIR}/arm64_dir" && mkdir -p "${WORK_DIR}/arm64" && mv "${WORK_DIR}/arm64_dir" "${WORK_DIR}/arm64/Clipboard.app" 2>/dev/null || true
# Simpler: just keep it named Clipboard.app inside its own subfolder:
ARM64_DIR="${WORK_DIR}/arm64_bundle"
X86_DIR="${WORK_DIR}/x86_bundle"
mkdir -p "$ARM64_DIR" "$X86_DIR"
rm -rf "${ARM64_DIR}/Clipboard.app" "${X86_DIR}/Clipboard.app"
cp -R "$UNIVERSAL_APP" "${ARM64_DIR}/Clipboard.app"
cp -R "$UNIVERSAL_APP" "${X86_DIR}/Clipboard.app"
thin_app "arm64" "${ARM64_DIR}/Clipboard.app"
thin_app "x86_64" "${X86_DIR}/Clipboard.app"

echo "==> Packaging DMGs..."
make_dmg "${ARM64_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-arm64.dmg"
make_dmg "${X86_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-x86_64.dmg"
make_dmg "$UNIVERSAL_APP" "${DIST_DIR}/Clipboard-${VERSION}-universal.dmg"

echo "==> Packaging ZIPs..."
make_zip "${ARM64_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-arm64.zip"
make_zip "${X86_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-x86_64.zip"
make_zip "$UNIVERSAL_APP" "${DIST_DIR}/Clipboard-${VERSION}-universal.zip"

echo "==> Artifacts packaging complete:"
ls -lh "${DIST_DIR}"
