#!/usr/bin/env bash
# Screenshots of each screen on the simulator, with the 9:41 status bar, into scripts/out/.
# Build first: xcodebuild -project Murmur.xcodeproj -scheme Murmur \
#   -destination 'platform=iOS Simulator,name=iPhone 16 (Murmur)' -derivedDataPath build/DerivedData build
#   scripts/screenshots.sh            all screens
#   scripts/screenshots.sh home debug  only these routes
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 16 (Murmur)}"
APP_ID="${APP_ID:-com.antonmironenko.murmur}"
ROUTES=("$@")
[ ${#ROUTES[@]} -eq 0 ] && ROUTES=(home settings languages debug transcript swipeBack)
mkdir -p scripts/out

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
app_path=$(find build/DerivedData/Build/Products/Debug-iphonesimulator -maxdepth 1 -name Murmur.app | head -1)
if [ -z "$app_path" ]; then
  echo "No simulator build in build/DerivedData; build the Murmur scheme first." >&2
  exit 1
fi
xcrun simctl install "$SIM" "$app_path"

status=0
for route in "${ROUTES[@]}"; do
  xcrun simctl launch --terminate-running-process "$SIM" "$APP_ID" -route "$route" -fixtures >/dev/null
  sleep 2.5
  out="scripts/out/$route.png"
  if xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    echo "$out"
  else
    echo "missing: $out" >&2
    status=1
  fi
done
xcrun simctl terminate "$SIM" "$APP_ID" >/dev/null 2>&1 || true
exit $status
