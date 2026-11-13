# shellcheck shell=bash
# Shared by gcp.sh and fly.sh (sourced, never run on its own). Written for the bash 3.2 that macOS ships.

DEPLOY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$DEPLOY_DIR/../.." && pwd)
OUT_DIR="$REPO_ROOT/scripts/out"
STATE_DIR="$OUT_DIR/deploy"
HOSTS_FILE="$OUT_DIR/network_test/hosts.txt"
BENCH_KEY_FILE="$OUT_DIR/live_bench.env"
# The only files a host ever receives: the server and the handlers it imports. Never the working
# folder, which holds Apple keys, env files and the app.
SHIP_PATHS="server/main.ts server/Dockerfile server/Dockerfile.dockerignore supabase/functions/_shared supabase/functions/live/spike.ts"
HOURS_PER_MONTH=730

DRY_RUN=0
ASSUME_YES=0

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() {
  printf 'Stopped: %s\n' "$*" >&2
  exit 1
}

# A command as it would be typed, quoted where needed.
quoted() {
  local out="" arg
  for arg in "$@"; do
    case $arg in
      "" | *[!A-Za-z0-9_./:=@,+%-]*) out="$out '$(printf %s "$arg" | sed "s/'/'\\\\''/g")'" ;;
      *) out="$out $arg" ;;
    esac
  done
  printf '%s' "${out# }"
}

# Runs a command that changes something; with --dry-run, prints it instead. Secrets never travel as
# arguments (they go in files or on stdin), so a printed command shows none.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry run] %s\n' "$(quoted "$@")"
    return 0
  fi
  "$@"
}

# Asks before anything is created or deleted: the answer must be exactly $2.
confirm() {
  local answer=""
  if [ "$ASSUME_YES" = 1 ]; then return 0; fi
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would ask: $1 (type $2)"
    return 0
  fi
  printf '%s Type %s to go on: ' "$1" "$2" >/dev/tty
  read -r answer </dev/tty || true
  [ "$answer" = "$2" ] || die "nothing was changed."
}

# need <command> <where to get it>: stops early when a tool is missing (not in a dry run, which runs none).
need() {
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  command -v "$1" >/dev/null 2>&1 || die "$1 isn't installed. $2"
}

# Dollars: money <awk expression> prints it with cents.
money() { awk "BEGIN { printf \"%.2f\", $1 }"; }

# One line of the cost table: cost_line <what> <dollars>.
cost_line() { printf '  %-62s $%7s\n' "$1" "$2"; }

# The commit to ship, and its short name (the version every reply's /healthz shows).
commit_of() { git -C "$REPO_ROOT" rev-parse --verify --quiet "$1^{commit}" || die "there is no commit $1"; }
version_of() { git -C "$REPO_ROOT" rev-parse --short=12 "$(commit_of "$1")"; }

# stage_source <ref> <dir>: the server's files at that commit, and nothing else, into an empty folder.
stage_source() {
  local ref=$1 dir=$2 commit unexpected
  commit=$(commit_of "$ref")
  mkdir -p "$dir"
  # shellcheck disable=SC2086 # SHIP_PATHS is a list of paths
  git -C "$REPO_ROOT" archive --format=tar "$commit" -- $SHIP_PATHS | tar -x -C "$dir"
  find "$dir" -name '*_test.ts' -type f -exec rm -f {} +
  unexpected=$(cd "$dir" && find . -type f | grep -v -E '^\./(server/(main\.ts|Dockerfile|Dockerfile\.dockerignore)|supabase/functions/_shared/.+\.ts|supabase/functions/live/spike\.ts)$' || true)
  [ -z "$unexpected" ] || die "the staged copy holds files it shouldn't: $unexpected"
}

files_in() { find "$1" -type f | wc -l | tr -d ' '; }

# The bench key from scripts/out/live_bench.env, for the network test; never printed.
bench_key() {
  local key
  [ -f "$BENCH_KEY_FILE" ] || die "there is no $BENCH_KEY_FILE: it holds the key the network test uses on every host."
  key=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}LIVE_BENCH_KEY=//p' "$BENCH_KEY_FILE" | head -n 1)
  key=${key%\"}
  key=${key#\"}
  key=${key%\'}
  key=${key#\'}
  [ -n "$key" ] || die "$BENCH_KEY_FILE sets no LIVE_BENCH_KEY."
  printf '%s' "$key"
}

# Everything temporary (the staged copy, files holding secrets) lives in one folder only this user
# can read, removed when the script ends, however it ends.
WORK_DIR=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/murmur-deploy.XXXXXX") || die "couldn't make a temporary folder"
remove_work_dir() {
  case $WORK_DIR in
    */murmur-deploy.??????) [ -d "$WORK_DIR" ] && rm -rf "$WORK_DIR" ;;
  esac
}
trap remove_work_dir EXIT

# A new file in it (safe to call in $(…): the folder, not a variable, is what gets cleaned up).
private_file() { (umask 077 && mktemp "$WORK_DIR/env.XXXXXX"); }

# MURMUR_KEEP_STAGE=<folder>: a copy of exactly what is shipped is left there, to look at.
keep_stage() {
  [ -n "${MURMUR_KEEP_STAGE:-}" ] || return 0
  mkdir -p "$MURMUR_KEEP_STAGE"
  cp -R "$1/." "$MURMUR_KEEP_STAGE/"
  say "A copy of what is shipped: $MURMUR_KEEP_STAGE"
}

# check_env_file <file>: an env file of NAME=VALUE lines, kept outside the repository (or in the
# git-ignored scripts/out). Prints the names it sets, never the values.
check_env_file() {
  local file=$1 dir names
  [ -f "$file" ] || die "there is no file $file"
  dir=$(cd "$(dirname "$file")" && pwd -P)
  case "$dir/" in
    "$REPO_ROOT/scripts/out/"*) ;;
    "$REPO_ROOT/"*) die "$file is inside the repository, where a commit could pick it up. Keep it outside (e.g. ~/murmur/server.env) or in scripts/out/." ;;
  esac
  if grep -v -E '^[[:space:]]*(#.*)?$' "$file" | grep -q -v -E '^[A-Z_][A-Z0-9_]*='; then
    die "$file has lines that aren't NAME=VALUE (no export, no spaces around =)."
  fi
  if grep -q -E '^PORT=' "$file"; then die "$file sets PORT: the server's port is fixed by the setup; remove that line."; fi
  names=$(grep -E '^[A-Z_][A-Z0-9_]*=' "$file" | cut -d= -f1 | tr '\n' ' ')
  say "Variables in $file: ${names% }"
  if ! grep -q -E '^LIVE_BENCH_KEY=' "$file"; then
    warn "Note: no LIVE_BENCH_KEY in it, so this host will stop answering the network test."
  fi
}

# set_host_line <network> <url>: the network test's hosts list gets this host (replacing one of the same name).
set_host_line() {
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would add to ${HOSTS_FILE#"$REPO_ROOT"/}: $1 $2"
    return 0
  fi
  mkdir -p "$(dirname "$HOSTS_FILE")"
  touch "$HOSTS_FILE"
  { grep -v -E "^$1[[:space:]]" "$HOSTS_FILE" || true; printf '%s %s\n' "$1" "$2"; } >"$HOSTS_FILE.new"
  mv "$HOSTS_FILE.new" "$HOSTS_FILE"
  say "The network test now includes $1: ${HOSTS_FILE#"$REPO_ROOT"/}"
}

remove_host_line() {
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would remove $1 from ${HOSTS_FILE#"$REPO_ROOT"/}"
    return 0
  fi
  [ -f "$HOSTS_FILE" ] || return 0
  { grep -v -E "^$1[[:space:]]" "$HOSTS_FILE" || true; } >"$HOSTS_FILE.new"
  mv "$HOSTS_FILE.new" "$HOSTS_FILE"
}

# State: what was created, so later commands find it. KEY=value lines in scripts/out/deploy (git-ignored).
save_state() { # save_state <file> KEY=value…
  local file=$1
  shift
  if [ "$DRY_RUN" = 1 ]; then return 0; fi
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$@" >"$file"
}
state_value() { # state_value <file> <KEY>
  [ -f "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -n 1
}

# wait_healthy <url> <seconds>: until /healthz answers 200.
wait_healthy() {
  local url=$1 limit=$2 waited=0
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would wait for $url to answer"
    return 0
  fi
  while [ "$waited" -lt "$limit" ]; do
    if curl -fsS --max-time 5 "$url" 2>/dev/null; then
      printf '\n'
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  warn "$url didn't answer in $limit s."
  return 1
}
