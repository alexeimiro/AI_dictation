#!/bin/bash
# The Murmur VM's startup script (Google Compute Engine runs it as root at every boot; gcp.sh passes
# it as the startup-script metadata). It installs what the server needs, once: Docker, curl,
# automatic security updates, rotated container logs, and a swap file on a 1 GB machine. The server
# and Caddy are started by gcp.sh over ssh, and Docker brings them back after a reboot.
set -euo pipefail
log() { echo "murmur-startup: $*"; }

mkdir -p /var/lib/murmur /opt/murmur/releases
install -d -m 700 /etc/murmur

# Container logs rotate, so a server that runs for months can't fill the disk.
if [ ! -f /etc/docker/daemon.json ]; then
  mkdir -p /etc/docker
  printf '{ "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "5" } }\n' >/etc/docker/daemon.json
fi

# A 1 GB machine (e2-micro) builds the image more safely with some swap.
mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
if [ "$mem_kb" -lt 1500000 ] && [ ! -f /swapfile ]; then
  log "adding 1 GB of swap"
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

if ! command -v docker >/dev/null 2>&1; then
  log "installing Docker"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y -q docker.io curl ca-certificates unattended-upgrades
  # Security updates install themselves every day.
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
  systemctl enable --now docker
fi

touch /var/lib/murmur/startup-done
log "done"
