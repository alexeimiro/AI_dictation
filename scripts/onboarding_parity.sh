#!/usr/bin/env bash
# Screenshots of every onboarding state next to its reference (artifacts/wispr-onboarding), on an
# iPhone 16 Pro simulator (402 × 874 pt, the capture's size).
#
#   scripts/onboarding_parity.sh            build, then shoot all 42 states
#   scripts/onboarding_parity.sh 04 21 33   only these references
#   SKIP_BUILD=1 scripts/onboarding_parity.sh
#
# Output (build/onboarding-parity/, gitignored):
#   NN.png          our screen
#   NN-compare.png  reference | ours | 50% overlay
#   contact-sheet.png and compare-sheet.png  all states in a grid
#
# System-owned states (iOS Settings, permission prompts) can't be produced by the app: 11–15 use the
# annotated reference, 18 and 36 show the app screen the prompt appears over.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM="${SIM:-iPhone 16 Pro (Onboarding)}"
APP_ID="${APP_ID:-com.antonmironenko.murmur}"
DERIVED="${DERIVED:-build/OnboardingDD}"
REF=artifacts/wispr-onboarding
LABEL_FONT=App/Resources/Fonts/Figtree-SemiBold.ttf
OUT=build/onboarding-parity
mkdir -p "$OUT"

# NN|kind|launch arguments. kind: app (overlay-compared), prompt (system dialog over this screen),
# system (iOS Settings, not the app), home (after onboarding).
STATES=(
  "01|app|-onboarding-step welcome -onboarding-variant dictionary"
  "02|app|-onboarding-step welcome -onboarding-variant speed"
  "03|app|-onboarding-step welcome -onboarding-variant languages"
  "04|app|-onboarding-step useCases"
  "05|app|-onboarding-step personalizedExplainer"
  "06|app|-onboarding-step signIn"
  "07|app|-onboarding-step signInOptions"
  "08|app|-onboarding-step emailSignIn"
  "09|app|-onboarding-step setupIntro"
  "10|app|-onboarding-step keyboardInstructions"
  "11|system|"
  "12|system|"
  "13|system|"
  "14|system|"
  "15|system|"
  "16|app|-onboarding-step practiceIntro"
  "17|app|-onboarding-step microphonePrimer"
  "18|prompt|-onboarding-step microphonePrimer"
  "19|prompt|-onboarding-step basicPractice -onboarding-variant guide"
  "20|app|-onboarding-step basicPractice -onboarding-variant guide"
  "21|app|-onboarding-step basicPractice -onboarding-variant ready"
  "22|app|-onboarding-step basicPractice -onboarding-variant listening"
  "23|app|-onboarding-step basicPractice -onboarding-variant result"
  "24|app|-onboarding-step formattingPractice -onboarding-variant ready"
  "25|app|-onboarding-step formattingPractice -onboarding-variant result"
  "26|app|-onboarding-step whisperIntro"
  "27|app|-onboarding-step whisperPractice -onboarding-variant ready"
  "28|app|-onboarding-step whisperPractice -onboarding-variant listening"
  "29|app|-onboarding-step whisperPractice -onboarding-variant result"
  "30|app|-onboarding-step practiceComplete"
  "31|app|-onboarding-step wrapUpIntro"
  "32|app|-onboarding-step dataChoice -onboarding-variant improve"
  "33|app|-onboarding-step languages"
  "34|app|-onboarding-step defaultStyle"
  "35|app|-onboarding-step notifications"
  "36|prompt|-onboarding-step notifications"
  "37|app|-onboarding-step desktopOffer"
  "38|app|-onboarding-step referralSource"
  "39|app|-onboarding-step referralDetail"
  "40|app|-onboarding-step ready"
  "41|app|-onboarding-step trialOffer -onboarding-variant trial"
  "42|home|-onboarding-step complete"
)

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Murmur.xcodeproj -scheme Murmur -destination "platform=iOS Simulator,name=$SIM" \
    -derivedDataPath "$DERIVED" build -quiet
fi
app_path=$(find "$DERIVED/Build/Products/Debug-iphonesimulator" -maxdepth 1 -name Murmur.app | head -1)
[ -n "$app_path" ] || { echo "No build in $DERIVED" >&2; exit 1; }

xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
xcrun simctl status_bar "$SIM" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4
xcrun simctl install "$SIM" "$app_path"

wanted=("$@")
selected() {
  [ ${#wanted[@]} -eq 0 ] && return 0
  for w in "${wanted[@]}"; do [ "$w" = "$1" ] && return 0; done
  return 1
}

for state in "${STATES[@]}"; do
  IFS='|' read -r nn kind args <<< "$state"
  selected "$nn" || continue
  ref=$(ls "$REF"/"$nn"-*.png | head -1)
  out="$OUT/$nn.png"
  if [ "$kind" = system ]; then
    magick "$ref" -fill '#000000A0' -draw "rectangle 0,0 1206,180" -fill white -font "$LABEL_FONT" -pointsize 54 \
      -gravity north -annotate +0+60 "iOS Settings — system-owned" "$out"
  else
    # shellcheck disable=SC2086
    xcrun simctl launch --terminate-running-process "$SIM" "$APP_ID" $args >/dev/null
    sleep "${SETTLE:-2.5}"
    xcrun simctl io "$SIM" screenshot "$out" >/dev/null 2>&1
    if [ "$kind" = prompt ]; then
      magick "$out" -fill '#000000A0' -draw "rectangle 0,0 1206,180" -fill white -font "$LABEL_FONT" -pointsize 50 \
        -gravity north -annotate +0+60 "System prompt appears over this" "$out"
    fi
  fi
  magick "$ref" "$out" -compose blend -define compose:args=50,50 -composite "$OUT/$nn-overlay.png"
  magick "$ref" "$out" "$OUT/$nn-overlay.png" +append -resize 50% "$OUT/$nn-compare.png"
  echo "$nn ($kind) → $out"
done
xcrun simctl terminate "$SIM" "$APP_ID" >/dev/null 2>&1 || true

if [ ${#wanted[@]} -eq 0 ]; then
  magick montage -font "$LABEL_FONT" "$OUT"/[0-9][0-9].png -tile 6x7 -geometry 201x437+4+4 -background white "$OUT/contact-sheet.png"
  magick montage -font "$LABEL_FONT" "$OUT"/[0-9][0-9]-compare.png -tile 3x14 -geometry 603x437+6+6 -background white "$OUT/compare-sheet.png"
  echo "$OUT/contact-sheet.png"
fi
