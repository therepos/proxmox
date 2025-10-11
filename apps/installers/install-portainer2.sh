#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-portainer2.sh?$(date +%s))"
# purpose: installs portainer docker
# updating:
#  docker stop portainer
#  docker rm portainer
#  <rerun the script to get the latest version>

set -euo pipefail

GREEN="\e[32m✔\e[0m"; RED="\e[31m✘\e[0m"; BLUE="\e[34mℹ\e[0m"
ok(){ echo -e "${GREEN} $*"; }
info(){ echo -e "${BLUE} $*"; }
fail(){ echo -e "${RED} $*"; exit 1; }

MODE="${MODE:-install}"   # install|update|uninstall
IMAGE="portainer/portainer-ce:lts"
NAME="portainer"

command -v docker >/dev/null || fail "Docker not found"
[[ -S /var/run/docker.sock ]] || fail "Docker socket missing: /var/run/docker.sock"

HOST_BIND="/mnt/sec/apps"
[[ -n "${HOST_BIND}" ]] && mkdir -p "${HOST_BIND}"

case "$MODE" in
  uninstall)
    info "Stopping/removing ${NAME}"
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker volume rm portainer_data >/dev/null 2>&1 || true
    ok "Uninstalled"; exit 0
    ;;
  update)
    info "Updating image ${IMAGE}"
    docker pull "${IMAGE}" >/dev/null
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    ;;
  install) : ;;
  *) fail "Unknown MODE='${MODE}' (use install|update|uninstall)";;
esac

docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null

SOCK_GID="$(stat -c '%g' /var/run/docker.sock)"

info "Starting ${NAME} (HTTPS 9443)"
docker rm -f "${NAME}" >/dev/null 2>&1 || true
docker run -d --name "${NAME}" \
  --pull=always \
  --restart=always \
  --security-opt apparmor=unconfined \
  --security-opt seccomp=unconfined \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  $( [[ -n "${HOST_BIND}" ]] && echo "-v ${HOST_BIND}:/mnt/sec/apps" ) \
  --group-add "${SOCK_GID}" \
  "${IMAGE}" \
  -H unix:///var/run/docker.sock >/dev/null

for i in {1..30}; do
  docker ps --format '{{.Names}}' | grep -qx "${NAME}" && break
  sleep 1
done

IP=$(hostname -I | awk '{print $1}')
if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
  ok "Portainer is up at https://${IP}:9443"
else
  fail "Container failed to start"
fi

