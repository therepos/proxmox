#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-portainer.sh?$(date +%s))"
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

# ensure docker is present
command -v docker >/dev/null || fail "Docker not found"

# optional bind (create if present in script)
HOST_BIND="/mnt/sec/apps"
if [[ -n "${HOST_BIND}" ]]; then
  mkdir -p "${HOST_BIND}"
fi

case "$MODE" in
  uninstall)
    info "Stopping/removing ${NAME}"
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    docker volume rm portainer_data >/dev/null 2>&1 || true
    ok "Uninstalled"
    exit 0
    ;;
  update)
    info "Updating image ${IMAGE}"
    docker pull "${IMAGE}"
    docker rm -f "${NAME}" >/dev/null 2>&1 || true
    ;;
  install) : ;;
  *) fail "Unknown MODE='${MODE}' (use install|update|uninstall)";;
esac

# create volume if missing
docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null

# run (idempotent; --pull=always ensures the image is fresh)
info "Starting ${NAME}"
docker run -d --name "${NAME}" \
  --pull=always \
  --restart=always \
  -p 8000:8000 \
  -p 9443:9443 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  $( [[ -n "${HOST_BIND}" ]] && echo "-v ${HOST_BIND}:/mnt/sec/apps" ) \
  "${IMAGE}" >/dev/null

# wait up to ~30s for healthy/running
for i in {1..30}; do
  if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then break; fi
  sleep 1
done

IP=$(hostname -I | awk '{print $1}')
if docker ps --format '{{.Names}}' | grep -qx "${NAME}"; then
  ok "Portainer is up at https://${IP}:9443"
else
  fail "Container failed to start"
fi

