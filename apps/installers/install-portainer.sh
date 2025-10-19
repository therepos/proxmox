#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-portainer.sh?$(date +%s))"
# purpose: installs portainer docker 
# version: pve9

set -euo pipefail

# Settings
IMAGE="portainer/portainer-ce:lts"
NAME="portainer"
PORT_HTTPS="9443"
HOST_BIND="/mnt/sec/apps"   # optional; leave empty to disable

# Helpers
GREEN="\e[32m✔\e[0m"
RED="\e[31m✘\e[0m"
BLUE="\e[34mℹ\e[0m"

ok(){ echo -e "${GREEN} $*"; }
info(){ echo -e "${BLUE} $*"; }
fail(){ echo -e "${RED} $*"; exit 1; }
asknum(){ # asknum "prompt" "min" "max" "default"
  local p="$1" min="$2" max="$3" def="$4" in
  while true; do
    read -rp "$p [$min-$max, 0 to exit] (default: $def): " in </dev/tty || in="$def"
    in="${in:-$def}"
    [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( in==0 || (in>=min && in<=max) )) && { echo "$in"; return; }
  done
}

# Prechecks
command -v docker >/dev/null || fail "Docker not found"
[[ -S /var/run/docker.sock ]] || fail "Docker socket missing: /var/run/docker.sock"
[[ -n "${HOST_BIND}" ]] && mkdir -p "${HOST_BIND}"

exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; }

start_portainer(){
  local sock_gid; sock_gid="$(stat -c '%g' /var/run/docker.sock)"
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${NAME}" \
    --pull=always --restart=always \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    -p ${PORT_HTTPS}:${PORT_HTTPS} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    $( [[ -n "${HOST_BIND}" ]] && echo "-v ${HOST_BIND}:/mnt/sec/apps" ) \
    --group-add "${sock_gid}" \
    "${IMAGE}" \
    -H unix:///var/run/docker.sock >/dev/null

  for _ in {1..30}; do
    docker ps --format '{{.Names}}' | grep -qx "${NAME}" && break
    sleep 1
  done
  if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    local ip; ip=$(hostname -I | awk '{print $1}')
    ok "Portainer is up at https://${ip}:${PORT_HTTPS}"
  else
    fail "Container failed to start"
  fi
}

update_portainer(){
  info "Pulling ${IMAGE}…"
  docker pull "${IMAGE}" >/dev/null
  info "Restarting ${NAME}…"
  start_portainer
}

uninstall_portainer(){ # auto-clean everything
  info "Stopping/removing container…"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  info "Removing volume 'portainer_data'…"
  docker volume rm portainer_data >/dev/null 2>&1 || true
  info "Removing Portainer images…"
  docker images --format '{{.Repository}}:{{.Tag}}' \
    | grep -i '^portainer/portainer-ce:' \
    | xargs -r docker rmi -f >/dev/null 2>&1 || true
  ok "Uninstalled Portainer (container, volume, images)."
}

# Menu
if exists_container; then
  echo "Portainer is already installed. What would you like to do?"
  echo "1) Update"
  echo "2) Uninstall (auto-clean)"
  echo "0) Exit"
  choice="$(asknum 'Enter choice' 1 2 1)"
  case "$choice" in
    0) ok "Bye."; exit 0 ;;
    1) update_portainer ;;
    2) uninstall_portainer ;;
  esac
else
  echo "Portainer is not installed. What would you like to do?"
  echo "1) Install"
  echo "0) Exit"
  choice="$(asknum 'Enter choice' 1 1 1)"
  case "$choice" in
    0) ok "Bye."; exit 0 ;;
    1) start_portainer ;;
  esac
fi
