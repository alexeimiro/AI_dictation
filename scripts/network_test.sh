#!/bin/sh
# The network-test evening in one command: from the connection this Mac is on now, tests every host
# in scripts/out/network_test/hosts.txt and today's Supabase at once, then prints the evening's table.
#
#   scripts/network_test.sh home-wifi          # then beeline, mts, … on the iPhone's hotspot, VPN off
#   scripts/network_test.sh beeline --quick    # a 1-minute check first, kept apart from the evening
#   scripts/network_test.sh --report           # the table so far, nothing run
#
# Options are scripts/bench/network_test.ts's (--help). The bench key is read from
# scripts/out/live_bench.env (git-ignored) and handed to the test in its environment, never printed.
set -eu
cd "$(dirname "$0")/.."

key_file=scripts/out/live_bench.env
if [ ! -f "$key_file" ]; then
  echo "No $key_file: the bench key the hosts answer to is kept there. See server/deploy/README.md." >&2
  exit 1
fi
set -a
. "./$key_file"
set +a
if [ -z "${LIVE_BENCH_KEY:-}" ]; then
  echo "$key_file doesn't set LIVE_BENCH_KEY." >&2
  exit 1
fi

# The first argument, unless it is an option, names the connection.
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  connection=$1
  shift
  set -- --connection "$connection" "$@"
fi

exec deno run --allow-net --allow-read --allow-write --allow-env --allow-run scripts/bench/network_test.ts "$@"
