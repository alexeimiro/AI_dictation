#!/bin/bash
# On the Murmur VM, as root; gcp.sh copies it there and calls it over ssh.
#
#   vm_remote.sh caddy <host>                 HTTPS for <host> in front of the server (certificate from Let's Encrypt)
#   vm_remote.sh env <file>                   installs the server's variables (/etc/murmur/server.env, mode 600), then restarts it
#   vm_remote.sh release <version> <tarball>  builds that version (unless its image is here) and swaps it in
#   vm_remote.sh status                       what runs, and each slot's /healthz
#
# The server runs in one of two slots, 127.0.0.1:8080 or :8081. A release starts the new version in
# the free slot, waits for its /healthz, then stops the old one, which drains (DRAIN_MS) while Caddy,
# checking both slots every 2 s, sends new requests to the new one. Nothing is dropped, and the
# previous version's image stays here, so going back is a release of it with no build.
set -euo pipefail

CADDY_IMAGE=caddy:2.11.6
ENV_FILE=/etc/murmur/server.env
# The server's DRAIN_MS (30 s) and 10 s more.
STOP_SECONDS=40
# Images kept for going back, the running one included.
KEEP_IMAGES=4

install -d -m 755 /opt/murmur /opt/murmur/releases
# A copy stays, so `status` works after /tmp is cleared.
if [ "$(readlink -f "$0")" != /opt/murmur/vm_remote.sh ]; then install -m 755 "$0" /opt/murmur/vm_remote.sh; fi

running() { docker ps --format '{{.Names}}' | grep -E '^murmur-80(80|81)$' | head -n 1 || true; }
version_of() { docker inspect -f '{{ index .Config.Labels "murmur.version" }}' "$1" 2>/dev/null || true; }

caddy() {
  local host=$1
  cat >/etc/murmur/Caddyfile <<EOF
# Written by vm_remote.sh: HTTPS for $host, in front of the server's two slots.
$host {
	reverse_proxy 127.0.0.1:8080 127.0.0.1:8081 {
		lb_policy first
		lb_try_duration 5s
		health_uri /healthz
		health_interval 2s
		health_timeout 2s
	}
}
EOF
  docker rm -f caddy >/dev/null 2>&1 || true
  docker run -d --name caddy --restart unless-stopped --network host \
    -v /etc/murmur/Caddyfile:/etc/caddy/Caddyfile:ro -v caddy_data:/data -v caddy_config:/config \
    "$CADDY_IMAGE" >/dev/null
  echo "caddy=$host"
}

release() {
  local version=$1 tarball=${2:-} dir image old port healthy=0 previous=""
  dir=/opt/murmur/releases/$version
  image=murmur-server:$version
  [ -f "$ENV_FILE" ] || { echo "no $ENV_FILE: run gcp.sh env first" >&2; exit 1; }
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    [ -n "$tarball" ] && [ -f "$tarball" ] || { echo "no image $image here and nothing to build it from" >&2; exit 1; }
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir"
    echo "building $image"
    docker build -q -f "$dir/server/Dockerfile" --build-arg "MURMUR_VERSION=$version" -t "$image" "$dir" >/dev/null
  fi
  [ -z "$tarball" ] || rm -f "$tarball"

  old=$(running)
  if [ "$old" = murmur-8080 ]; then port=8081; else port=8080; fi
  docker rm -f "murmur-$port" >/dev/null 2>&1 || true
  docker run -d --name "murmur-$port" --restart unless-stopped --stop-timeout "$STOP_SECONDS" \
    --env-file "$ENV_FILE" -p "127.0.0.1:$port:8080" --label "murmur.version=$version" "$image" >/dev/null
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
      healthy=1
      break
    fi
    sleep 1
  done
  if [ "$healthy" != 1 ]; then
    echo "version $version didn't answer /healthz in 60 s: removed; the running one keeps serving" >&2
    docker logs --tail 40 "murmur-$port" >&2 || true
    docker rm -f "murmur-$port" >/dev/null
    exit 1
  fi
  if [ -n "$old" ]; then
    previous=$(version_of "$old")
    # Caddy sees the old slot's /healthz turn 503 as it drains and moves new requests over.
    docker stop -t "$STOP_SECONDS" "$old" >/dev/null
    docker rm "$old" >/dev/null
  fi
  # Older images go; the newest few stay for going back.
  docker images murmur-server --format '{{.CreatedAt}}|{{.Repository}}:{{.Tag}}' | sort -r | tail -n +$((KEEP_IMAGES + 1)) |
    cut -d'|' -f2 | while read -r stale; do docker rmi "$stale" >/dev/null 2>&1 || true; done
  echo "live=$version slot=$port previous=${previous:-none}"
}

env_install() {
  local src=$1 current
  install -m 600 -o root -g root "$src" "$ENV_FILE"
  rm -f "$src"
  current=$(running)
  if [ -n "$current" ]; then
    release "$(version_of "$current")" ""
  else
    echo "variables installed; no server runs yet"
  fi
}

status() {
  docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  for port in 8080 8081; do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/healthz" 2>/dev/null; then echo "  (slot $port)"; fi
  done
}

case "${1:-}" in
  caddy) caddy "$2" ;;
  env) env_install "$2" ;;
  release) release "$2" "${3:-}" ;;
  status) status ;;
  *) echo "usage: vm_remote.sh caddy <host> | env <file> | release <version> [tarball] | status" >&2; exit 2 ;;
esac
