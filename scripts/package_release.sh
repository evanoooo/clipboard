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

thin_app() {
  local target_arch="$1"
  local app_bundle="$2"
  find "$app_bundle" -type f -perm +111 | while read -r bin; do
    if lipo -info "$bin" 2>/dev/null | grep -q "Architectures in the fat file.*$target_arch"; then
      lipo "$bin" -thin "$target_arch" -output "$bin.tmp" && mv "$bin.tmp" "$bin"
    fi
  done
}

KEYCHAIN_FLAG=()
for kc in "/Users/opm/Library/Keychains/login.keychain-db" "${HOME}/Library/Keychains/login.keychain-db" "${HOME}/Library/Keychains/login.keychain"; do
  if [ -f "$kc" ]; then
    KEYCHAIN_FLAG=(--keychain "$kc")
    break
  fi
done

DEFAULT_IDENTITY="NativeToolbox Dev"
IDENTITY_TO_USE="${SIGN_IDENTITY:-$DEFAULT_IDENTITY}"

sign_bundle() {
  local app_bundle="$1"
  local identity="$IDENTITY_TO_USE"
  echo "==> Re-signing bundle with identity '${identity}': $app_bundle"
  if [ -d "$app_bundle/Contents/Frameworks" ]; then
    find "$app_bundle/Contents/Frameworks" -type d -name "*.framework" -o -type f -name "*.dylib" 2>/dev/null | while read -r fw; do
      codesign "${KEYCHAIN_FLAG[@]}" --force --deep -s "${identity}" "$fw" 2>/dev/null || codesign --force --deep -s - "$fw" 2>/dev/null || true
    done
  fi
  if ! codesign "${KEYCHAIN_FLAG[@]}" --force --deep -s "${identity}" "$app_bundle" 2>/dev/null; then
    echo "==> Identity '${identity}' failed or not found, falling back to ad-hoc (-)"
    codesign --force --deep -s - "$app_bundle"
  fi
}

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

ARM64_DIR="${WORK_DIR}/arm64_bundle"
X86_DIR="${WORK_DIR}/x86_bundle"
UNIVERSAL_DIR="${WORK_DIR}/universal_bundle"

mkdir -p "$ARM64_DIR" "$X86_DIR" "$UNIVERSAL_DIR"
cp -R "$UNIVERSAL_APP" "${ARM64_DIR}/Clipboard.app"
cp -R "$UNIVERSAL_APP" "${X86_DIR}/Clipboard.app"
cp -R "$UNIVERSAL_APP" "${UNIVERSAL_DIR}/Clipboard.app"

thin_app "arm64" "${ARM64_DIR}/Clipboard.app"
thin_app "x86_64" "${X86_DIR}/Clipboard.app"

echo "==> Signing bundles with identity '${SIGN_IDENTITY:--}'..."
sign_bundle "${ARM64_DIR}/Clipboard.app"
sign_bundle "${X86_DIR}/Clipboard.app"
sign_bundle "${UNIVERSAL_DIR}/Clipboard.app"

echo "==> Packaging DMGs..."
make_dmg "${ARM64_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-arm64.dmg"
make_dmg "${X86_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-x86_64.dmg"
make_dmg "${UNIVERSAL_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-universal.dmg"

echo "==> Packaging ZIPs..."
make_zip "${ARM64_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-arm64.zip"
make_zip "${X86_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-x86_64.zip"
make_zip "${UNIVERSAL_DIR}/Clipboard.app" "${DIST_DIR}/Clipboard-${VERSION}-universal.zip"

echo "==> Artifacts packaging complete:"
ls -lh "${DIST_DIR}"
