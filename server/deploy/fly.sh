#!/usr/bin/env bash
# The dictation server (server/main.ts) on Fly.io, always on: one machine, created, updated, removed.
#
#   server/deploy/fly.sh [plan]          what it would create and what that costs a month; creates nothing
#   server/deploy/fly.sh create          the app, its addresses, the server answering the network test only
#   server/deploy/fly.sh deploy          a new version; Fly starts it beside the old one and switches once it is healthy
#   server/deploy/fly.sh env <file>      the server's variables (Fly secrets) from a file outside the repository
#   server/deploy/fly.sh status          the machine, the addresses, /healthz
#   server/deploy/fly.sh delete          the app and everything in it, so nothing keeps billing
#
# Options: --region finland|stockholm|frankfurt|amsterdam (finland, which is Stockholm, arn: Fly has no
#          Finland region) · --app <name> (murmur-edge-<random>, kept for later commands) · --org <slug>
#          (personal) · --network <name in the network test> (fly) · --dedicated-ipv4 (+$2 a month; the
#          default shared IPv4 is free) · --ref <commit> (HEAD: what is shipped is that commit, never
#          uncommitted files) · --yes (don't ask) · --dry-run (print every fly command, run none; works
#          without flyctl or an account)
#
# Needs: flyctl (brew install flyctl), logged in (fly auth login), a payment method on the account.
# Fly builds the image on its own builders from a folder holding only the server's files.
set -euo pipefail
# shellcheck source=server/deploy/common.sh
. "$(dirname "$0")/common.sh"

# MARK: Prices
# Read on 2026-11-13 at https://docs.fly.io/about/pricing, USD: a started shared-cpu-1x machine with
# 1 GB RAM is $6.70 for a 30-day month in the cheapest regions, times the region's markup on that
# page (Stockholm and Amsterdam 1.038461538, Frankfurt 1.153846154: $7.73, as the page's own example
# says). Shared IPv4 and IPv6: free. Dedicated IPv4: $2/month. Data out in Europe: $0.02/GB.
# Builders: free. A personal organization's bill under $5 a month is waived.
MACHINE_30_DAYS=6.70
IPV4_DEDICATED=2.00
EGRESS_PER_GB=0.02
EGRESS_ESTIMATE_GB=2

# MARK: Options

COMMAND=plan
REGION=finland
APP=""
ORG=personal
NETWORK=fly
DEDICATED_IPV4=0
REF=HEAD
ENV_SOURCE=""
while [ $# -gt 0 ]; do
  case $1 in
    plan | create | deploy | status | delete) COMMAND=$1 ;;
    env)
      COMMAND=env
      ENV_SOURCE=${2:-}
      [ -n "$ENV_SOURCE" ] || die "env needs a file: fly.sh env ~/murmur/server.env"
      shift
      ;;
    --region) REGION=${2:?--region needs finland, stockholm, frankfurt or amsterdam}; shift ;;
    --app) APP=${2:?}; shift ;;
    --org) ORG=${2:?}; shift ;;
    --network) NETWORK=${2:?}; shift ;;
    --dedicated-ipv4) DEDICATED_IPV4=1 ;;
    --ref) REF=${2:?}; shift ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument $1 (fly.sh --help)" ;;
  esac
  shift
done

STATE_FILE="$STATE_DIR/fly.env"
if [ -z "$APP" ]; then APP=$(state_value "$STATE_FILE" APP); fi
if [ -f "$STATE_FILE" ]; then
  case " $* " in *" --region "*) ;; *)
    saved=$(state_value "$STATE_FILE" REGION)
    [ -z "$saved" ] || REGION=$saved
    ;;
  esac
fi

case $REGION in
  finland | stockholm | arn) FLY_REGION=arn; PLACE="Stockholm"; MARKUP=1.038461538 ;;
  frankfurt | fra) FLY_REGION=fra; PLACE="Frankfurt"; MARKUP=1.153846154 ;;
  amsterdam | ams) FLY_REGION=ams; PLACE="Amsterdam"; MARKUP=1.038461538 ;;
  *) die "--region is finland (Stockholm), stockholm, frankfurt or amsterdam" ;;
esac
HOST_TAG="fly-$FLY_REGION"

new_app_name() { printf 'murmur-edge-%s' "$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"; }

# MARK: What it costs

print_plan() {
  local machine ip egress total day app=${APP:-murmur-edge-<random>}
  machine=$(money "$MACHINE_30_DAYS * $MARKUP / 720 * $HOURS_PER_MONTH")
  ip=$(money "$DEDICATED_IPV4 * $IPV4_DEDICATED")
  egress=$(money "$EGRESS_ESTIMATE_GB * $EGRESS_PER_GB")
  total=$(money "$machine + $ip + $egress")
  day=$(money "($machine + $ip) / $HOURS_PER_MONTH * 24")
  say "Fly.io, $PLACE ($FLY_REGION), organization $ORG:"
  say "  app $app at https://$app.fly.dev: one always-on machine (shared-cpu-1x, 1 GB), never stopped for idling"
  if [ "$DEDICATED_IPV4" = 1 ]; then say "  a dedicated IPv4 and an IPv6 address"; else say "  a shared IPv4 (free) and an IPv6 address"; fi
  say "  the server from $(version_of "$REF"), built on Fly's builders"
  say ""
  say "What it costs, list prices on 2026-11-13 (docs.fly.io/about/pricing), USD, a $HOURS_PER_MONTH-hour month:"
  cost_line "shared-cpu-1x, 1 GB, in $PLACE (\$$MACHINE_30_DAYS x $(money "$MARKUP") region price)" "$machine"
  if [ "$DEDICATED_IPV4" = 1 ]; then cost_line "dedicated IPv4" "$ip"; else cost_line "shared IPv4 and IPv6" "0.00"; fi
  cost_line "traffic out, ~$EGRESS_ESTIMATE_GB GB (\$$EGRESS_PER_GB/GB)" "$egress"
  say "  ───────────────────────────────────────────────────────────────────────"
  cost_line "a month" "$total"
  cost_line "a day, if it is deleted after the network test" "$day"
  say ""
  say "Fly waives a personal organization's bill under \$5 a month, so a test of a day or two costs nothing;"
  say "kept running, it is billed in full."
}

# MARK: Doing it

# stage: the server's files at --ref, and a fly.toml for this app, in an empty folder ($STAGE/src).
stage() {
  local version=$1
  STAGE=$(mktemp -d "$WORK_DIR/stage.XXXXXX")
  stage_source "$REF" "$STAGE/src"
  cat >"$STAGE/src/fly.toml" <<EOF
# Written by server/deploy/fly.sh for $APP at $version: the dictation server, always on.
app = "$APP"
primary_region = "$FLY_REGION"
# The server drains on SIGTERM for up to DRAIN_MS (30 s); Fly waits this long before killing it.
kill_signal = "SIGTERM"
kill_timeout = 40

[build]
  dockerfile = "server/Dockerfile"

[build.args]
  MURMUR_VERSION = "$version"

[env]
  MURMUR_HOST = "$HOST_TAG"
  MURMUR_REGION = "$FLY_REGION"

[http_service]
  internal_port = 8080
  force_https = true
  auto_stop_machines = "off"
  auto_start_machines = true
  min_machines_running = 1

  [http_service.concurrency]
    type = "connections"
    soft_limit = 200
    hard_limit = 250

  [[http_service.checks]]
    grace_period = "10s"
    interval = "15s"
    method = "GET"
    path = "/healthz"
    timeout = "5s"

[[vm]]
  size = "shared-cpu-1x"
  memory = "1gb"
EOF
  keep_stage "$STAGE/src"
  say "Staged $version: $(files_in "$STAGE/src") files (the server's, and fly.toml), nothing else from this folder."
}

fly_deploy() { # fly_deploy <version> <strategy>: from the staged folder, built on Fly's builders
  say "Deploying from the staged folder (Fly uploads only that folder to its builder):"
  (cd "$STAGE/src" && run fly deploy --app "$APP" --config fly.toml --remote-only --ha=false --strategy "$2" \
    --image-label "git-$1" --wait-timeout 5m --yes)
}

cmd_create() {
  local version env_file
  need fly "Install flyctl (brew install flyctl), then: fly auth login"
  [ -n "$APP" ] || APP=$(new_app_name)
  print_plan
  say ""
  confirm "Create the app $APP?" yes
  run fly auth whoami
  if [ "$DRY_RUN" != 1 ] && fly status --app "$APP" >/dev/null 2>&1; then
    say "The app $APP exists already: using it."
  else
    run fly apps create "$APP" --org "$ORG"
  fi
  save_state "$STATE_FILE" "APP=$APP" "ORG=$ORG" "REGION=$FLY_REGION" "NETWORK=$NETWORK"

  # The network test's one secret; this home's name and region are in fly.toml.
  env_file=$(private_file)
  printf 'LIVE_BENCH_KEY=%s\n' "$(bench_key)" >"$env_file"
  say "Setting the secret LIVE_BENCH_KEY from ${BENCH_KEY_FILE#"$REPO_ROOT"/} (on stdin, never on a command line)."
  run fly secrets import --app "$APP" --stage <"$env_file"

  if [ "$DEDICATED_IPV4" = 1 ]; then
    run fly ips allocate-v4 --app "$APP" --yes
  else
    run fly ips allocate-v4 --app "$APP" --shared
  fi
  run fly ips allocate-v6 --app "$APP"

  version=$(version_of "$REF")
  stage "$version"
  # The first deploy has no machine to switch from: it just starts one.
  fly_deploy "$version" rolling
  save_state "$STATE_FILE" "APP=$APP" "ORG=$ORG" "REGION=$FLY_REGION" "NETWORK=$NETWORK" "LIVE_VERSION=$version"
  wait_healthy "https://$APP.fly.dev/healthz" 120 || warn "Check it later with: server/deploy/fly.sh status"
  set_host_line "$NETWORK" "wss://$APP.fly.dev/functions/v1/live"
  say ""
  say "Done. The server answers the network test only, until fly.sh env gives it the project's variables."
  say "When the test is over and this network lost: server/deploy/fly.sh delete"
}

cmd_deploy() {
  local version previous
  need fly "Install flyctl first."
  [ -n "$APP" ] || die "no app recorded in ${STATE_FILE#"$REPO_ROOT"/}: run fly.sh create first, or pass --app"
  previous=$(state_value "$STATE_FILE" LIVE_VERSION)
  version=$(version_of "$REF")
  stage "$version"
  # The new machine starts beside the old one and takes over once its /healthz passes.
  fly_deploy "$version" bluegreen
  save_state "$STATE_FILE" "APP=$APP" "ORG=$ORG" "REGION=$FLY_REGION" "NETWORK=$NETWORK" "LIVE_VERSION=$version" "PREVIOUS_VERSION=$previous"
  wait_healthy "https://$APP.fly.dev/healthz" 60 || true
  say "Live: $version."
  if [ -n "$previous" ] && [ "$previous" != "$version" ]; then
    say "Roll back with: server/deploy/fly.sh deploy --ref $previous"
    say "  or, with no build: fly deploy --app $APP --image registry.fly.io/$APP:git-$previous --strategy bluegreen (from a staged folder with its fly.toml)"
  fi
}

cmd_env() {
  need fly "Install flyctl first."
  [ -n "$APP" ] || die "no app recorded: run fly.sh create first, or pass --app"
  check_env_file "$ENV_SOURCE"
  say "Fly keeps these as secrets and restarts the machine with them (MURMUR_HOST and MURMUR_REGION stay in fly.toml)."
  run fly secrets import --app "$APP" <"$ENV_SOURCE"
  wait_healthy "https://$APP.fly.dev/healthz" 60 || true
}

cmd_status() {
  need fly "Install flyctl first."
  [ -n "$APP" ] || die "no app recorded: run fly.sh create first, or pass --app"
  say "App $APP, https://$APP.fly.dev, live version (recorded here): $(state_value "$STATE_FILE" LIVE_VERSION)"
  run fly status --app "$APP"
  run fly ips list --app "$APP"
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would ask https://$APP.fly.dev/healthz"
  else
    curl -sS --max-time 10 "https://$APP.fly.dev/healthz" || warn "https://$APP.fly.dev/healthz didn't answer"
    printf '\n'
  fi
}

cmd_delete() {
  need fly "Install flyctl first."
  [ -n "$APP" ] || die "no app recorded: pass --app <name>"
  say "This deletes the Fly app $APP: its machine, addresses, secrets and images."
  confirm "Delete it?" "$APP"
  run fly apps destroy "$APP" --yes
  remove_host_line "$NETWORK"
  if [ "$DRY_RUN" != 1 ]; then rm -f "$STATE_FILE"; fi
  say "Deleted. To be sure nothing bills: https://fly.io/dashboard (Billing)"
}

if [ "$DRY_RUN" = 1 ]; then say "(dry run: every fly command is printed, none is run)"; fi
case $COMMAND in
  plan) print_plan; say ""; say "Nothing was created. To create it: server/deploy/fly.sh create" ;;
  create) cmd_create ;;
  deploy) cmd_deploy ;;
  env) cmd_env ;;
  status) cmd_status ;;
  delete) cmd_delete ;;
esac
