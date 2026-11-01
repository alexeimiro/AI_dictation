#!/usr/bin/env bash
# Archives Murmur (Release) and uploads it to App Store Connect for TestFlight.
#
# Signing is manual, with the App Store profiles and distribution certificate created by
# `node scripts/provision_dev.mjs --appstore`. The upload uses the API key in Config/asc.env.
# The build number is a timestamp, so every run uploads a new build.
#   scripts/testflight_upload.sh             provision if needed, archive, upload
#   scripts/testflight_upload.sh --refresh   recreate the profiles first
set -euo pipefail
cd "$(dirname "$0")/.."
source Config/asc.env

profiles_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
installed=$({ grep -l "Murmur AppStore" "$profiles_dir"/*.mobileprovision 2>/dev/null || true; } | wc -l | tr -d ' ')
if [[ "${1:-}" == "--refresh" || "$installed" -lt 3 ]]; then
  node scripts/provision_dev.mjs --appstore
fi

build_number=$(date +%Y%m%d%H%M)
archive=build/Murmur.xcarchive
export_dir=build/export
rm -rf "$archive" "$export_dir"

xcodegen generate -q
xcodebuild -project Murmur.xcodeproj -scheme Murmur -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath build/DerivedData \
  -archivePath "$archive" \
  CURRENT_PROJECT_VERSION="$build_number" \
  MURMUR_SIGN_STYLE=Manual \
  MURMUR_SIGN_IDENTITY="Apple Distribution" \
  MURMUR_PROFILE_APP="Murmur AppStore App" \
  MURMUR_PROFILE_KEYBOARD="Murmur AppStore Keyboard" \
  MURMUR_PROFILE_WIDGETS="Murmur AppStore Widgets" \
  archive | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" | sort -u
[[ -d "$archive" ]] || exit 1

cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>DMC53DDZQV</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key>
  <dict>
    <key>com.antonmironenko.murmur</key><string>Murmur AppStore App</string>
    <key>com.antonmironenko.murmur.keyboard</key><string>Murmur AppStore Keyboard</string>
    <key>com.antonmironenko.murmur.widgets</key><string>Murmur AppStore Widgets</string>
  </dict>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
  -exportOptionsPlist build/ExportOptions.plist | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" | sort -u
[[ -f "$export_dir/Murmur.ipa" ]] || exit 1

# altool finds the .p8 in ~/.appstoreconnect/private_keys by key ID.
xcrun altool --upload-app --type ios --file "$export_dir/Murmur.ipa" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
echo "Uploaded build $build_number. It appears in TestFlight after processing (5–30 min)."
