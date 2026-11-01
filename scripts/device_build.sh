#!/usr/bin/env bash
# Builds Murmur for iPhone and installs it on every test device (over Wi-Fi once paired).
#
# Signing is manual, with development profiles created through the App Store Connect API by
# scripts/provision_dev.mjs (xcodebuild's own API-key provisioning is rejected for this key).
# Reads Config/asc.env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, DEVICE_UDID (comma-separated).
#   scripts/device_build.sh             provision if needed, build, install
#   scripts/device_build.sh --refresh   recreate the profiles first (after adding a device or
#                                       changing capabilities)
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/asc.env

profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
installed=$({ grep -l "Murmur Dev" "$profiles_dir"/*.mobileprovision 2>/dev/null || true; } | wc -l | tr -d ' ')
if [[ "${1:-}" == "--refresh" || "$installed" -lt 3 ]]; then
  node scripts/provision_dev.mjs
fi

# A generic destination: a phone that's asleep on Wi-Fi isn't offered as a destination, but the
# install below wakes it.
xcodegen generate -q
xcodebuild -project Murmur.xcodeproj -scheme Murmur \
  -destination "generic/platform=iOS" \
  -derivedDataPath build/DerivedData \
  MURMUR_SIGN_STYLE=Manual \
  MURMUR_PROFILE_APP="Murmur Dev App" \
  MURMUR_PROFILE_KEYBOARD="Murmur Dev Keyboard" \
  MURMUR_PROFILE_WIDGETS="Murmur Dev Widgets" \
  build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u

status=0
IFS=',' read -ra udids <<< "$DEVICE_UDID"
for udid in "${udids[@]}"; do
  echo "Installing on $udid"
  xcrun devicectl device install app --device "$udid" \
    build/DerivedData/Build/Products/Debug-iphoneos/Murmur.app || status=1
done
exit $status
