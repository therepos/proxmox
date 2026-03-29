#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/install-gitlab.sh?$(date +%s))"
# Purpose: Deploys GitLab CE with Runner, Container Registry and Pages via Docker Compose
# Version: Docker (Ubuntu/Debian host)
# =============================================================================
# Usage:
#   Fetches docker-compose.yml from GitHub and deploys GitLab CE
#   Patches host IP into the compose file automatically
#   Waits for GitLab to become healthy before printing credentials
#   Includes GitLab Runner, Container Registry and GitLab Pages
#   Supports optional environment variables:
#     GITLAB_HOST       - hostname or IP (default: auto-detected LAN IP)
#     GITLAB_DATA_DIR   - persistent data root (default: /mnt/sec/apps/gitlab)
# =============================================================================

set -euo pipefail

# Helpers
info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

# Config
COMPOSE_URL="https://github.com/therepos/proxmox/raw/main/apps/docker/gitlab-docker-compose.yml"
PLACEHOLDER_IP="192.168.1.111"
PLACEHOLDER_DIR="/mnt/sec/apps/gitlab"

# Root check
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Docker check
command -v docker &> /dev/null || fail "Docker is not installed. Install Docker first."
docker compose version &> /dev/null || fail "Docker Compose (v2 plugin) is not available."

echo ""
echo "GitLab CE - One-Click Deploy"
echo "================================================="
echo ""

# Resolve host IP
HOST_IP=$(hostname -I | awk '{print $1}')
GITLAB_HOST="${GITLAB_HOST:-${HOST_IP}}"
DATA_DIR="${GITLAB_DATA_DIR:-/mnt/sec/apps/gitlab}"
COMPOSE_DIR="${DATA_DIR}/compose"

info "Host:           ${GITLAB_HOST}"
info "Web UI:         http://${GITLAB_HOST}:3028"
info "SSH clone:      ssh://git@${GITLAB_HOST}:2224"
info "Registry:       http://${GITLAB_HOST}:5050"
info "Pages:          http://${GITLAB_HOST}:8090"
info "Data directory: ${DATA_DIR}"
echo ""

# Create directories
info "Creating directories..."
mkdir -p "${DATA_DIR}"/{config,logs,data}
mkdir -p "${DATA_DIR}/runner/config"
mkdir -p "${COMPOSE_DIR}"
ok "Directories created."

# Fetch docker-compose.yml
info "Fetching docker-compose.yml from GitHub..."
if command -v wget &> /dev/null; then
    wget -qO "${COMPOSE_DIR}/docker-compose.yml" "${COMPOSE_URL}?$(date +%s)"
elif command -v curl &> /dev/null; then
    curl -fsSL "${COMPOSE_URL}?$(date +%s)" -o "${COMPOSE_DIR}/docker-compose.yml"
else
    fail "Neither wget nor curl found. Cannot download compose file."
fi
ok "docker-compose.yml downloaded."

# Patch host IP
if [[ "${GITLAB_HOST}" != "${PLACEHOLDER_IP}" ]]; then
    info "Patching host IP (${PLACEHOLDER_IP} -> ${GITLAB_HOST})..."
    sed -i "s/${PLACEHOLDER_IP}/${GITLAB_HOST}/g" "${COMPOSE_DIR}/docker-compose.yml"
    ok "Host IP patched."
else
    info "Host IP matches placeholder. No patching needed."
fi

# Patch data directory
if [[ "${DATA_DIR}" != "${PLACEHOLDER_DIR}" ]]; then
    info "Patching data directory (${PLACEHOLDER_DIR} -> ${DATA_DIR})..."
    sed -i "s|${PLACEHOLDER_DIR}|${DATA_DIR}|g" "${COMPOSE_DIR}/docker-compose.yml"
    ok "Data directory patched."
fi

# Pull images
info "Pulling Docker images (this may take a few minutes)..."
cd "${COMPOSE_DIR}"
docker compose pull
ok "Images pulled."

# Deploy
info "Starting GitLab..."
docker compose up -d
ok "Containers started."

# Wait for healthy
info "Waiting for GitLab to initialise (this takes 3-5 minutes)..."
SECONDS=0
MAX_WAIT=600
while true; do
    STATUS=$(docker inspect --format='{{.State.Health.Status}}' gitlab 2>/dev/null || echo "starting")
    if [[ "${STATUS}" == "healthy" ]]; then
        ok "GitLab is healthy."
        break
    fi
    if (( SECONDS > MAX_WAIT )); then
        warn "GitLab has not become healthy after ${MAX_WAIT}s."
        warn "It may still be initialising. Check: docker logs gitlab"
        break
    fi
    printf "\r[*] Status: %-12s (%ds elapsed)" "${STATUS}" "${SECONDS}"
    sleep 10
done
echo ""

# Retrieve initial root password
ROOT_PW=""
if docker exec gitlab test -f /etc/gitlab/initial_root_password 2>/dev/null; then
    ROOT_PW=$(docker exec gitlab cat /etc/gitlab/initial_root_password 2>/dev/null \
        | grep "^Password:" | awk '{print $2}')
fi

# Summary
echo ""
echo "Install Complete"
echo "================================================="
echo ""
echo "  Web UI          http://${GITLAB_HOST}:3028"
echo "  SSH clone       ssh://git@${GITLAB_HOST}:2224"
echo "  Registry        http://${GITLAB_HOST}:5050"
echo "  Pages           http://${GITLAB_HOST}:8090"
echo ""
echo "  Username        root"
if [[ -n "${ROOT_PW}" ]]; then
    echo "  Password        ${ROOT_PW}"
else
    echo "  Password        docker exec gitlab cat /etc/gitlab/initial_root_password"
fi
echo ""
echo "  Data directory  ${DATA_DIR}"
echo "  Compose file    ${COMPOSE_DIR}/docker-compose.yml"
echo ""
echo "  The initial root password expires after 24 hours."
echo "  Change it at: http://${GITLAB_HOST}:3028/-/user_settings/password/edit"
echo ""
echo "  To register a CI runner:"
echo "    1. GitLab > Admin > CI/CD > Create Instance Runner"
echo "    2. Create a tag > Create Runner, then:"
echo "         docker exec -it gitlab-runner bash"
echo "         gitlab-runner register --url http://gitlab:80 --token glrt-<TOKEN>"
echo "       Prompts:  url=http://gitlab:80  executor=docker  image=docker:latest"
echo "    3. Edit ${DATA_DIR}/runner/config/config.toml"
echo "       Under [runners.docker] set:"
echo "         privileged = true"
echo "         volumes = [\"/var/run/docker.sock:/var/run/docker.sock\"]"
echo "    4. docker restart gitlab-runner"
echo ""
echo "  To stop:    cd ${COMPOSE_DIR} && docker compose down"
echo "  To restart: cd ${COMPOSE_DIR} && docker compose up -d"
echo ""