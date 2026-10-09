#!/usr/bin/env bash
# Builds Murmur for the iPhone and installs it.
#
# Signing is manual, with development profiles created through the App Store Connect API by
# scripts/provision_dev.mjs (xcodebuild's own API-key provisioning is rejected for this key).
# Reads Config/asc.env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, DEVICE_UDID.
#   scripts/device_build.sh             provision if needed, build, install
#   scripts/device_build.sh --refresh   recreate the profiles first (e.g. after capability changes)
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/asc.env

profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
installed=$({ grep -l "Murmur Dev" "$profiles_dir"/*.mobileprovision 2>/dev/null || true; } | wc -l | tr -d ' ')
if [[ "${1:-}" == "--refresh" || "$installed" -lt 3 ]]; then
  node scripts/provision_dev.mjs
fi

xcodegen generate -q
xcodebuild -project Murmur.xcodeproj -scheme Murmur \
  -destination "platform=iOS,id=$DEVICE_UDID" \
  -derivedDataPath build/DerivedData \
  MURMUR_SIGN_STYLE=Manual \
  MURMUR_PROFILE_APP="Murmur Dev App" \
  MURMUR_PROFILE_KEYBOARD="Murmur Dev Keyboard" \
  MURMUR_PROFILE_WIDGETS="Murmur Dev Widgets" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u

xcrun devicectl device install app --device "$DEVICE_UDID" \
  build/DerivedData/Build/Products/Debug-iphoneos/Murmur.app
