#!/usr/bin/env bash
# Fails if a file in the repo still mentions the apps and capture sets Murmur's first UI was
# modelled on. Murmur's look and words are its own now; this keeps them that way.
#   scripts/check_no_wispr.sh
# It reads every tracked file and every new one that isn't ignored, and their names. This script
# and .gitignore are skipped (.gitignore still lists two local reference folders that were never
# part of the repo), and so is this script's own name where a document mentions it.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern='wispr|mobbin|references? [0-9]{2}|sampled from'
status=0
while IFS= read -r -d '' file; do
  # A file deleted from the working tree is still listed until the deletion is committed.
  [ -e "$file" ] || continue
  case "$file" in
    scripts/check_no_wispr.sh|.gitignore) continue ;;
  esac
  if printf '%s\n' "$file" | grep -qiE "$pattern"; then
    echo "$file: its name"
    status=1
  fi
  # Text files only (-I), with this script's name taken out of each line first.
  grep -Iq . "$file" 2>/dev/null || continue
  hits=$(sed 's/check_no_wispr\.sh//g' "$file" | grep -niE "$pattern" || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s|^|$file:|"
    status=1
  fi
done < <(git ls-files -z --cached --others --exclude-standard)

if [ "$status" -eq 0 ]; then
  echo "No mention of the reference apps."
fi
exit "$status"
