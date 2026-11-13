#!/usr/bin/env bash
# Screenshots of each screen on the simulator, with the 9:41 status bar, into scripts/out/.
# Build first: xcodebuild -project Murmur.xcodeproj -scheme Murmur \
#   -destination 'platform=iOS Simulator,name=iPhone 16 (Murmur)' -derivedDataPath build/DerivedData build
#   scripts/screenshots.sh              every route
#   scripts/screenshots.sh home debug    only these routes
#   scripts/screenshots.sh "home-on=-route home -session-fixture on"   a named shot with its own launch arguments
# SIM, DD (the derived data folder), OUT (where the PNGs go), WAIT (seconds before each shot) and
# SLOW_WAIT can be set in the environment. docs/APP_STORE.md has the command for the App Store's
# 6.9-inch set, and docs/ONBOARDING.md the launch arguments for onboarding's pages.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM="${SIM:-iPhone 16 (Murmur)}"
APP_ID="${APP_ID:-com.antonmironenko.murmur}"
DD="${DD:-build/DerivedData}"
OUT="${OUT:-scripts/out}"
WAIT="${WAIT:-2.5}"
# The transcript page prepares its recording before its first frame. A simulator whose audio is
# slow to start holds that for about 15 seconds, and a shot taken sooner shows the launch screen.
SLOW_WAIT="${SLOW_WAIT:-18}"
SHOTS=("$@")
[ ${#SHOTS[@]} -eq 0 ] && SHOTS=(home menu scratchpad dictionary snippets style settings languages account
                                 paywall referral transcript debug note
                                 "home-return-hint=-route home -session-fixture listening -return-hint Safari")
mkdir -p "$OUT"

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4
app_path=$(find "$DD/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name Murmur.app | head -1)
if [ -z "$app_path" ]; then
  echo "No simulator build in $DD; build the Murmur scheme first." >&2
  exit 1
fi
xcrun simctl install "$SIM" "$app_path"

status=0
for shot in "${SHOTS[@]}"; do
  if [[ "$shot" == *=* ]]; then
    name="${shot%%=*}"
    read -r -a launch_args <<< "${shot#*=}"
  else
    name="$shot"
    launch_args=(-route "$shot")
  fi
  wait="$WAIT"
  [[ " ${launch_args[*]} " == *" transcript "* ]] && wait="$SLOW_WAIT"
  xcrun simctl launch --terminate-running-process "$SIM" "$APP_ID" "${launch_args[@]}" -fixtures >/dev/null
  sleep "$wait"
  out="$OUT/$name.png"
  if xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1 && [ -s "$out" ]; then
    echo "$out"
  else
    echo "missing: $out" >&2
    status=1
  fi
done
xcrun simctl terminate "$SIM" "$APP_ID" >/dev/null 2>&1 || true
exit $status
