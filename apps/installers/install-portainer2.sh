#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-portainer2.sh?$(date +%s))"
# purpose: installs portainer docker
# updating:
#  docker stop portainer
#  docker rm portainer
#  <rerun the script to get the latest version>

set -euo pipefail

# ===== settings =====
IMAGE="portainer/portainer-ce:lts"
NAME="portainer"
PORT_HTTPS="9443"
HOST_BIND="/mnt/sec/apps"   # optional bind; leave empty to skip

# ===== ui helpers =====
GREEN="\e[32m✔\e[0m"; RED="\e[31m✘\e[0m"; BLUE="\e[34mℹ\e[0m"
ok(){ echo -e "${GREEN} $*"; }
info(){ echo -e "${BLUE} $*"; }
fail(){ echo -e "${RED} $*"; exit 1; }
ask(){ # ask "Question" "default"
  local q="$1" d="${2:-}"
  local p=" [$d]"; [[ -z "$d" ]] && p=""
  read -rp "$q$p: " REPLY </dev/tty || true
  REPLY="${REPLY:-$d}"
}

# ===== prechecks =====
command -v docker >/dev/null || fail "Docker not found"
[[ -S /var/run/docker.sock ]] || fail "Docker socket missing: /var/run/docker.sock"
[[ -n "${HOST_BIND}" ]] && mkdir -p "${HOST_BIND}"

# ===== helpers =====
start_portainer(){
  local sock_gid; sock_gid="$(stat -c '%g' /var/run/docker.sock)"
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

  # wait up to ~30s
  for i in {1..30}; do
    docker ps --format '{{.Names}}' | grep -qx "${NAME}" && break
    sleep 1
  done
  if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
    IP=$(hostname -I | awk '{print $1}')
    ok "Portainer is up at https://${IP}:${PORT_HTTPS}"
  else
    fail "Container failed to start"
  fi
}

uninstall_portainer(){
  info "Stopping/removing ${NAME}"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  ask "Remove Portainer data volume 'portainer_data'? (y/N)" "N"
  if [[ "${REPLY^^}" == "Y" ]]; then
    docker volume rm portainer_data >/dev/null 2>&1 || true
    ok "Removed volume portainer_data"
  fi
  ok "Uninstalled"
}

update_portainer(){
  info "Updating image ${IMAGE}"
  docker pull "${IMAGE}" >/dev/null
  info "Restarting ${NAME}"
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  # keep existing volume; just start again
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  start_portainer
}

install_portainer(){
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  start_portainer
}

# ===== main flow =====
if docker ps -a --format '{{.Names}}' | grep -qx "${NAME}"; then
  info "Detected existing Portainer container: ${NAME}"
  ask "Choose action: [U]pdate / [X] Uninstall / [S]kip" "U"
  case "${REPLY^^}" in
    U) update_portainer ;;
    X) uninstall_portainer ;;
    S) ok "Skipped";;
    *) fail "Unknown choice";;
  esac
else
  info "Portainer not installed"
  ask "Install Portainer now? (y/N)" "Y"
  if [[ "${REPLY^^}" == "Y" ]]; then
    install_portainer
  else
    ok "Nothing to do"
  fi
fi
