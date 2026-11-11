#!/bin/bash
# Draws Murmur's brand files from MurmurBrand: the app icon (light, dark, tinted), the launch logo
# and the asset catalog's colours.
#   scripts/build_brand.sh          writes them
#   scripts/build_brand.sh --check  writes nothing; fails if any is out of date
set -euo pipefail
cd "$(dirname "$0")/.."
swift run --quiet --package-path Tools/BrandKit brandkit "$PWD" "$@"
