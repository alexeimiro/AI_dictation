#!/usr/bin/env bash
# The dictation server (server/main.ts) on a small Google Cloud VM: created, updated, and removed.
#
#   server/deploy/gcp.sh [plan]          what it would create and what that costs a month; creates nothing
#   server/deploy/gcp.sh create          the VM, a static address, a firewall rule, Docker, Caddy (HTTPS),
#                                        and the server answering the network test only
#   server/deploy/gcp.sh deploy          a new version beside the running one; the old one stops once the new is healthy
#   server/deploy/gcp.sh env <file>      the server's variables from a file outside the repository, then a restart
#   server/deploy/gcp.sh status          the VM, its address, the server's /healthz
#   server/deploy/gcp.sh delete          everything create made, so nothing keeps billing
#
# Options: --region finland|frankfurt (finland) · --size small|micro (small: e2-small, 2 GB) · --project <id>
#          (gcloud's default project) · --name <vm> (murmur-edge) · --network <name in the network test> (google)
#          · --domain <name> (instead of <ip>.sslip.io; point its A record at the address first) · --ref <commit>
#          (HEAD: what is shipped is that commit, never uncommitted files) · --yes (don't ask) · --dry-run (print
#          every gcloud command, run none; works without gcloud or an account)
#
# Needs: the gcloud CLI, logged in (gcloud auth login), a project with billing (the free trial counts).
# The server gets only server/main.ts, its Dockerfile and the handlers it imports, as of the commit.
set -euo pipefail
# shellcheck source=server/deploy/common.sh
. "$(dirname "$0")/common.sh"

# MARK: Prices
# List prices read on 2026-11-13 on Google's own pages, USD:
#   machines: https://cloud.google.com/products/compute/pricing/general-purpose (E2 shared-core, on demand)
#   disk:     https://cloud.google.com/compute/disks-image-pricing ("Balanced provisioned space")
#   address:  https://cloud.google.com/vpc/network-pricing (a static or ephemeral IPv4 in use on a standard VM
#             $0.005/h; a static one reserved but unused $0.01/h)
#   traffic:  same page, Premium Tier internet data transfer out: first 1 GiB a month free, then $0.12/GiB
#   credit:   https://cloud.google.com/free ($300 for new customers; nothing is charged until the account is
#             upgraded to paid)
vm_hourly() {
  case "$GCP_REGION/$SIZE" in
    europe-north1/small) echo 0.01844439 ;;
    europe-north1/micro) echo 0.009222195 ;;
    europe-west3/small) echo 0.02158389 ;;
    europe-west3/micro) echo 0.010791945 ;;
  esac
}
disk_monthly_per_gb() { case $GCP_REGION in europe-north1) echo 0.11 ;; europe-west3) echo 0.12 ;; esac; }
IP_HOURLY=0.005
IP_UNUSED_HOURLY=0.01
EGRESS_PER_GB=0.12
EGRESS_FREE_GB=1
EGRESS_ESTIMATE_GB=2
DISK_GB=10

# MARK: Options

COMMAND=plan
REGION=finland
SIZE=small
PROJECT=""
NAME=murmur-edge
NETWORK=google
DOMAIN=""
REF=HEAD
ENV_SOURCE=""
while [ $# -gt 0 ]; do
  case $1 in
    plan | create | deploy | status | delete) COMMAND=$1 ;;
    env)
      COMMAND=env
      ENV_SOURCE=${2:-}
      [ -n "$ENV_SOURCE" ] || die "env needs a file: gcp.sh env ~/murmur/server.env"
      shift
      ;;
    --region) REGION=${2:?--region needs finland or frankfurt}; shift ;;
    --size) SIZE=${2:?--size needs small or micro}; shift ;;
    --project) PROJECT=${2:?}; shift ;;
    --name) NAME=${2:?}; shift ;;
    --network) NETWORK=${2:?}; shift ;;
    --domain) DOMAIN=${2:?}; shift ;;
    --ref) REF=${2:?}; shift ;;
    --yes) ASSUME_YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown argument $1 (gcp.sh --help)" ;;
  esac
  shift
done

STATE_FILE="$STATE_DIR/gcp-$NAME.env"
# A VM created earlier keeps its region, project and host unless told otherwise.
if [ -f "$STATE_FILE" ]; then
  [ -n "$PROJECT" ] || PROJECT=$(state_value "$STATE_FILE" PROJECT)
  saved_region=$(state_value "$STATE_FILE" REGION)
  case "$*" in *--region*) ;; *) [ -z "$saved_region" ] || REGION=$saved_region ;; esac
fi

case $REGION in
  finland | europe-north1) GCP_REGION=europe-north1; ZONE=europe-north1-a; PLACE="Finland"; HOST_TAG=gcp-fi ;;
  frankfurt | europe-west3) GCP_REGION=europe-west3; ZONE=europe-west3-a; PLACE="Frankfurt"; HOST_TAG=gcp-de ;;
  *) die "--region is finland or frankfurt" ;;
esac
case $SIZE in small | micro) ;; *) die "--size is small or micro" ;; esac
MACHINE=e2-$SIZE
ADDRESS="$NAME-ip"
FIREWALL="$NAME-web"

project() {
  if [ -n "$PROJECT" ]; then printf '%s' "$PROJECT"; return; fi
  if [ "$DRY_RUN" = 1 ]; then printf '%s' "<your-project>"; return; fi
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  [ -n "$PROJECT" ] && [ "$PROJECT" != "(unset)" ] || die "no project: pass --project <id>, or run gcloud config set project <id>"
  printf '%s' "$PROJECT"
}

# MARK: What it costs

print_plan() {
  local vm disk ip egress total day stopped
  vm=$(money "$(vm_hourly) * $HOURS_PER_MONTH")
  disk=$(money "$(disk_monthly_per_gb) * $DISK_GB")
  ip=$(money "$IP_HOURLY * $HOURS_PER_MONTH")
  egress=$(money "($EGRESS_ESTIMATE_GB - $EGRESS_FREE_GB) * $EGRESS_PER_GB")
  total=$(money "$vm + $disk + $ip + $egress")
  day=$(money "($vm + $disk + $ip) / $HOURS_PER_MONTH * 24")
  stopped=$(money "$disk + $IP_UNUSED_HOURLY * $HOURS_PER_MONTH")
  say "Google Cloud, $PLACE ($ZONE), project $(project):"
  say "  VM $NAME ($MACHINE, Debian 12, 10 GB balanced disk, tag $NAME), always on"
  say "  static IPv4 address $ADDRESS; firewall rule $FIREWALL (TCP 80 and 443 to the tag)"
  say "  Docker, Caddy (HTTPS for ${DOMAIN:-<address>.sslip.io}), and the server from $(version_of "$REF")"
  say ""
  say "What it costs, list prices on 2026-11-13 (Google's pricing pages), USD, a $HOURS_PER_MONTH-hour month:"
  cost_line "$MACHINE VM in $PLACE (\$$(vm_hourly)/hour)" "$vm"
  cost_line "$DISK_GB GB balanced disk (\$$(disk_monthly_per_gb)/GB-month)" "$disk"
  cost_line "static IPv4 address in use (\$$IP_HOURLY/hour)" "$ip"
  cost_line "traffic out, ~$EGRESS_ESTIMATE_GB GB (first $EGRESS_FREE_GB GB free, then \$$EGRESS_PER_GB/GB)" "$egress"
  say "  ───────────────────────────────────────────────────────────────────────"
  cost_line "a month" "$total"
  cost_line "a day, if it is deleted after the network test" "$day"
  say ""
  say "New Google Cloud accounts get \$300 of free credit, and nothing is charged until the account is"
  say "upgraded to paid. A stopped (not deleted) VM still pays for its disk and address: about \$$stopped a month."
}

# MARK: Doing it

ssh_vm() { run gcloud compute ssh "$NAME" --project "$(project)" --zone "$ZONE" --quiet --command "$1"; }

exists() { # exists <gcloud compute args…>: whether describing it succeeds
  [ "$DRY_RUN" = 1 ] && return 1
  gcloud compute "$@" --project "$(project)" --format='value(name)' >/dev/null 2>&1
}

load_vm() {
  [ -f "$STATE_FILE" ] || [ "$DRY_RUN" = 1 ] || die "no VM recorded in ${STATE_FILE#"$REPO_ROOT"/}: run gcp.sh create first"
  IP=$(state_value "$STATE_FILE" IP)
  HOST=$(state_value "$STATE_FILE" HOST)
  [ -n "$IP" ] || IP="<address>"
  [ -n "$HOST" ] || HOST="<address>.sslip.io"
}

# ship: the version at --ref, built on the VM and swapped in.
ship() {
  local version stage tarball result previous
  version=$(version_of "$REF")
  stage=$(mktemp -d "$WORK_DIR/stage.XXXXXX")
  stage_source "$REF" "$stage/src"
  keep_stage "$stage/src"
  tarball="$stage/murmur-$version.tgz"
  tar -czf "$tarball" -C "$stage/src" .
  say "Shipping $version: $(files_in "$stage/src") files from that commit ($(du -h "$tarball" | cut -f1 | tr -d ' ')), nothing else."
  run gcloud compute scp --project "$(project)" --zone "$ZONE" --quiet "$tarball" "$DEPLOY_DIR/vm_remote.sh" "$NAME:/tmp/"
  if [ "$DRY_RUN" = 1 ]; then
    ssh_vm "sudo bash /tmp/vm_remote.sh release $version /tmp/murmur-$version.tgz"
    return 0
  fi
  result=$(ssh_vm "sudo bash /tmp/vm_remote.sh release $version /tmp/murmur-$version.tgz" | tee /dev/stderr | grep '^live=' || true)
  [ -n "$result" ] || die "the release didn't finish; the version that was running keeps serving."
  previous=$(printf '%s' "$result" | sed -n 's/.*previous=\([^ ]*\).*/\1/p')
  save_state "$STATE_FILE" "PROJECT=$(project)" "REGION=$GCP_REGION" "ZONE=$ZONE" "NAME=$NAME" "IP=$IP" "HOST=$HOST" \
    "NETWORK=$NETWORK" "LIVE_VERSION=$version" "PREVIOUS_VERSION=$previous"
  say "Live: $version."
  if [ -n "$previous" ] && [ "$previous" != none ]; then
    say "Roll back with: server/deploy/gcp.sh deploy --ref $previous   (its image is still on the VM: no build)"
  fi
}

upload_env() { # upload_env <local file>
  run gcloud compute scp --project "$(project)" --zone "$ZONE" --quiet "$1" "$DEPLOY_DIR/vm_remote.sh" "$NAME:/tmp/"
  ssh_vm "sudo bash /tmp/vm_remote.sh env /tmp/$(basename "$1")"
}

cmd_create() {
  local env_file
  need gcloud "Install the Google Cloud CLI (https://cloud.google.com/sdk/docs/install), then: gcloud auth login"
  print_plan
  say ""
  confirm "Create these in project $(project)?" yes

  run gcloud services enable compute.googleapis.com --project "$(project)"
  if exists addresses describe "$ADDRESS" --region "$GCP_REGION"; then
    say "The address $ADDRESS exists already: using it."
  else
    run gcloud compute addresses create "$ADDRESS" --project "$(project)" --region "$GCP_REGION" --network-tier PREMIUM
  fi
  if [ "$DRY_RUN" = 1 ]; then
    IP="<address>"
  else
    IP=$(gcloud compute addresses describe "$ADDRESS" --project "$(project)" --region "$GCP_REGION" --format='value(address)')
  fi
  HOST=${DOMAIN:-$(printf '%s' "$IP" | tr . -).sslip.io}
  if exists firewall-rules describe "$FIREWALL"; then
    say "The firewall rule $FIREWALL exists already: using it."
  else
    run gcloud compute firewall-rules create "$FIREWALL" --project "$(project)" --network default --direction INGRESS \
      --action allow --rules tcp:80,tcp:443 --target-tags "$NAME" --source-ranges 0.0.0.0/0 \
      --description "Murmur dictation server: HTTPS, and HTTP for the certificate check"
  fi
  if exists instances describe "$NAME" --zone "$ZONE"; then
    say "The VM $NAME exists already: using it."
  else
    run gcloud compute instances create "$NAME" --project "$(project)" --zone "$ZONE" --machine-type "$MACHINE" \
      --image-family debian-12 --image-project debian-cloud --boot-disk-size "${DISK_GB}GB" --boot-disk-type pd-balanced \
      --address "$IP" --tags "$NAME" --labels app=murmur,role=edge \
      --shielded-secure-boot --shielded-vtpm --shielded-integrity-monitoring \
      --metadata-from-file "startup-script=$DEPLOY_DIR/vm_startup.sh"
  fi
  save_state "$STATE_FILE" "PROJECT=$(project)" "REGION=$GCP_REGION" "ZONE=$ZONE" "NAME=$NAME" "IP=$IP" "HOST=$HOST" "NETWORK=$NETWORK"

  say "Waiting for the VM to finish installing Docker (a minute or two)…"
  if [ "$DRY_RUN" = 1 ]; then
    ssh_vm "test -f /var/lib/murmur/startup-done"
  else
    local tries=0
    until gcloud compute ssh "$NAME" --project "$(project)" --zone "$ZONE" --quiet \
      --command "test -f /var/lib/murmur/startup-done" >/dev/null 2>&1; do
      tries=$((tries + 1))
      [ "$tries" -lt 40 ] || die "the VM didn't finish its setup in 10 minutes: see gcloud compute instances get-serial-port-output $NAME --zone $ZONE"
      sleep 15
    done
  fi

  # The network test's variables: the bench key, this home's name and region. Nothing else yet.
  env_file=$(private_file)
  printf 'LIVE_BENCH_KEY=%s\nMURMUR_HOST=%s\nMURMUR_REGION=%s\n' "$(bench_key)" "$HOST_TAG" "$GCP_REGION" >"$env_file"
  say "Setting the network test's variables (LIVE_BENCH_KEY from ${BENCH_KEY_FILE#"$REPO_ROOT"/}, MURMUR_HOST=$HOST_TAG, MURMUR_REGION=$GCP_REGION)."
  upload_env "$env_file"
  ssh_vm "sudo bash /tmp/vm_remote.sh caddy $HOST"
  ship
  say "Waiting for https://$HOST/healthz (the first certificate can take a minute)…"
  wait_healthy "https://$HOST/healthz" 180 || warn "Check it later with: server/deploy/gcp.sh status"
  set_host_line "$NETWORK" "wss://$HOST/functions/v1/live"
  say ""
  say "Done. The server answers the network test only, until gcp.sh env gives it the project's variables."
  say "When the test is over and this network lost: server/deploy/gcp.sh delete"
}

cmd_deploy() {
  need gcloud "Install the Google Cloud CLI first."
  load_vm
  ship
  wait_healthy "https://$HOST/healthz" 60 || true
}

cmd_env() {
  local env_file
  need gcloud "Install the Google Cloud CLI first."
  load_vm
  check_env_file "$ENV_SOURCE"
  env_file=$(private_file)
  cat "$ENV_SOURCE" >"$env_file"
  # This home's name and region, unless the file sets its own.
  grep -q -E '^MURMUR_HOST=' "$env_file" || printf 'MURMUR_HOST=%s\n' "$HOST_TAG" >>"$env_file"
  grep -q -E '^MURMUR_REGION=' "$env_file" || printf 'MURMUR_REGION=%s\n' "$GCP_REGION" >>"$env_file"
  upload_env "$env_file"
  wait_healthy "https://$HOST/healthz" 60 || true
}

cmd_status() {
  need gcloud "Install the Google Cloud CLI first."
  load_vm
  say "VM $NAME in $ZONE, project $(project): $( [ "$DRY_RUN" = 1 ] && echo "<state>" || gcloud compute instances describe "$NAME" --project "$(project)" --zone "$ZONE" --format='value(status)' 2>/dev/null || echo "not found")"
  say "Address $IP, https://$HOST"
  say "Live version (recorded here): $(state_value "$STATE_FILE" LIVE_VERSION)"
  if [ "$DRY_RUN" = 1 ]; then
    say "  [dry run] would ask https://$HOST/healthz"
  else
    curl -sS --max-time 10 "https://$HOST/healthz" || warn "https://$HOST/healthz didn't answer"
    printf '\n'
  fi
  ssh_vm "sudo bash /opt/murmur/vm_remote.sh status"
}

cmd_delete() {
  need gcloud "Install the Google Cloud CLI first."
  [ -f "$STATE_FILE" ] || [ -n "$PROJECT" ] || [ "$DRY_RUN" = 1 ] || die "no VM recorded; pass --project and --name to delete one by hand"
  say "This deletes, in project $(project): the VM $NAME ($ZONE) with its disk, the address $ADDRESS, the firewall rule $FIREWALL."
  say "The server's variables and certificates on it go too."
  confirm "Delete them?" "$NAME"
  run gcloud compute instances delete "$NAME" --project "$(project)" --zone "$ZONE" --delete-disks=all --quiet ||
    warn "The VM wasn't deleted (already gone?)."
  run gcloud compute firewall-rules delete "$FIREWALL" --project "$(project)" --quiet || warn "The firewall rule wasn't deleted (already gone?)."
  run gcloud compute addresses delete "$ADDRESS" --project "$(project)" --region "$GCP_REGION" --quiet ||
    warn "The address wasn't deleted (already gone?)."
  remove_host_line "$NETWORK"
  if [ "$DRY_RUN" != 1 ]; then rm -f "$STATE_FILE"; fi
  say "Deleted. To be sure nothing bills: https://console.cloud.google.com/billing"
}

if [ "$DRY_RUN" = 1 ]; then say "(dry run: every gcloud command is printed, none is run)"; fi
case $COMMAND in
  plan) print_plan; say ""; say "Nothing was created. To create it: server/deploy/gcp.sh create" ;;
  create) cmd_create ;;
  deploy) cmd_deploy ;;
  env) cmd_env ;;
  status) cmd_status ;;
  delete) cmd_delete ;;
esac
