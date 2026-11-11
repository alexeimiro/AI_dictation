#!/bin/bash
# Publishes Murmur's website to GitHub Pages: builds it (scripts/build_site.mjs), then pushes
# build/site as the whole content of the gh-pages branch, one commit per publish. Nothing on the
# current branch changes. GitHub serves it at https://simplymurmur.com/ (the build's CNAME file),
# and https://alexeimiro.github.io/AI_dictation/ redirects there.
#
# Usage: scripts/publish_site.sh
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$(pwd)"

node scripts/build_site.mjs

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export GIT_INDEX_FILE="$scratch/index"
(cd build/site && git --git-dir="$repo/.git" --work-tree=. add -A .)
tree="$(git write-tree)"

git fetch --quiet origin gh-pages 2>/dev/null || true
parent="$(git rev-parse --quiet --verify refs/remotes/origin/gh-pages || true)"
if [ -n "$parent" ] && [ "$(git rev-parse "$parent^{tree}")" = "$tree" ]; then
  echo "The website is already up to date."
  exit 0
fi
commit="$(git commit-tree "$tree" ${parent:+-p "$parent"} -m "Publish the website from $(git rev-parse --short HEAD)")"
git push origin "$commit:refs/heads/gh-pages"
echo "Published $commit. GitHub Pages serves it within a minute or two."
