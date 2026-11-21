#!/usr/bin/env bash
# Builds the Murmur for Mac download: a Release archive exported for Developer ID, notarized and
# stapled, inside a signed, notarized and stapled disk image (build/mac-release/Redmic.dmg).
#
# It builds from a clean copy of one commit, so other work in progress in this folder stays out of
# the download; --with-mac-changes copies the working copy's Mac/ folder (uncommitted changes
# included) over it. Signing uses the "Developer ID Application" identity in the login keychain
# and the "Murmur Mac Direct" profile (node Mac/scripts/provision_mac.mjs); notarization uses the
# API key in Config/asc.env. The build number is a timestamp, as for TestFlight.
#   Mac/scripts/release.sh                              HEAD
#   Mac/scripts/release.sh <commit>                     that commit
#   Mac/scripts/release.sh [<commit>] --with-mac-changes
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$PWD
source Config/asc.env

commit=HEAD
with_mac_changes=no
for arg in "$@"; do
  case $arg in
    --with-mac-changes) with_mac_changes=yes ;;
    *) commit=$arg ;;
  esac
done

work=$root/build/mac-release
identity="Developer ID Application: OKNENOR L.L.C-FZ (DMC53DDZQV)"
auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
build_number=$(date +%Y%m%d%H%M)

# 1. A clean copy, the project and the archive.
[[ -d "$work/dmg" ]] && { hdiutil detach -quiet -force "$work/dmg" 2>/dev/null || true; }
rm -rf "$work/src" "$work/Murmur.xcarchive" "$work/export" "$work/dmg" "$work"/*.zip "$work"/*.dmg
mkdir -p "$work/src"
git archive "$commit" | tar -x -C "$work/src"
cp Config/Local.xcconfig "$work/src/Config/"
if [[ $with_mac_changes == yes ]]; then
  rsync -a --delete --exclude MurmurMac.xcodeproj/ Mac/ "$work/src/Mac/"
fi
(cd "$work/src/Mac" && xcodegen generate --quiet)
resolved=MurmurMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [[ -f "Mac/$resolved" ]]; then
  mkdir -p "$(dirname "$work/src/Mac/$resolved")"
  cp "Mac/$resolved" "$work/src/Mac/$resolved"
fi
xcodebuild -project "$work/src/Mac/MurmurMac.xcodeproj" -scheme MurmurMac -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$work/DerivedData" \
  -archivePath "$work/Murmur.xcarchive" CURRENT_PROJECT_VERSION="$build_number" \
  archive > "$work/archive.log" 2>&1 || { grep -E "error:" "$work/archive.log" | sort -u | head -40; exit 1; }

cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>DMC53DDZQV</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>provisioningProfiles</key><dict><key>com.antonmironenko.murmur.mac</key><string>Murmur Mac Direct</string></dict>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$work/Murmur.xcarchive" -exportPath "$work/export" \
  -exportOptionsPlist "$work/ExportOptions.plist" > "$work/export.log" 2>&1 || { tail -30 "$work/export.log"; exit 1; }
app=$work/export/Redmic.app
codesign --verify --deep --strict "$app"

# 2. Notarize (Apple keeps a log of each submission) and staple.
notarize() {  # $1 the file to send, $2 a name for the result files
  xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout 30m --output-format json > "$work/notary-$2.json"
  local id result
  id=$(node -e 'console.log(require(process.argv[1]).id ?? "")' "$work/notary-$2.json")
  result=$(node -e 'console.log(require(process.argv[1]).status ?? "")' "$work/notary-$2.json")
  xcrun notarytool log "$id" "${auth[@]}" "$work/notary-$2-log.json" > /dev/null 2>&1 || true
  echo "notarization of the $2: $result ($id)"
  [[ $result == Accepted ]] || { cat "$work/notary-$2-log.json" 2>/dev/null; exit 1; }
}
ditto -c -k --keepParent "$app" "$work/Redmic-app.zip"
notarize "$work/Redmic-app.zip" app
xcrun stapler staple -q "$app"

# 3. The disk image: the app and a shortcut to Applications. Not `hdiutil create -srcfolder`: it
# mounts under /Volumes and failed every time with "Resource busy" (2026-11-16); `makehybrid`
# avoids mounting but gives files a Finder-info attribute that breaks codesign's strict check.
# So an empty image, mounted here and kept out of Spotlight, then compressed.
hdiutil create -quiet -size 64m -fs APFS -volname Redmic -type UDIF "$work/rw.dmg"
mkdir "$work/dmg"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$work/dmg" "$work/rw.dmg"
touch "$work/dmg/.metadata_never_index"
ditto "$app" "$work/dmg/Redmic.app"
ln -s /Applications "$work/dmg/Applications"
codesign --verify --deep --strict "$work/dmg/Redmic.app"
hdiutil detach -quiet "$work/dmg" || hdiutil detach -quiet -force "$work/dmg"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -o "$work/Redmic.dmg"
rm "$work/rw.dmg"
codesign -s "$identity" --timestamp "$work/Redmic.dmg"
notarize "$work/Redmic.dmg" dmg
xcrun stapler staple -q "$work/Redmic.dmg"

spctl -a -t exec -vv "$app"
spctl -a -t open --context context:primary-signature -vv "$work/Redmic.dmg"
echo "Murmur $(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist") ($build_number) from $(git rev-parse --short "$commit")$([[ $with_mac_changes == yes ]] && echo " + Mac/ changes")"
shasum -a 256 "$work/Redmic.dmg"
