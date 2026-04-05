#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/gitlab-setup.sh?$(date +%s))"
# Purpose: Deploys and manages GitLab CE with Runner, Container Registry and Pages (Ubuntu/PVE9)
# =============================================================================
# Usage:
#   Interactive menu to install and configure GitLab CE
#   1) Install GitLab        - fresh deploy via Docker Compose
#   2) Update default email  - change root user email via Rails console
#   3) Register runner       - register a CI runner with a token
#   4) Show status           - display service health and credentials
#   5) Upgrade GitLab        - backup secrets, pull latest, recreate
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
PLACEHOLDER_IP="192.168.1.100"
PLACEHOLDER_DIR="/mnt/sec/apps/gitlab"
HOST_IP=$(hostname -I | awk '{print $1}')
GITLAB_HOST="${GITLAB_HOST:-${HOST_IP}}"
DATA_DIR="${GITLAB_DATA_DIR:-/mnt/sec/apps/gitlab}"
COMPOSE_DIR="${DATA_DIR}/compose"

# Root check
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# Docker check
command -v docker &> /dev/null || fail "Docker is not installed. Install Docker first."
docker compose version &> /dev/null || fail "Docker Compose (v2 plugin) is not available."

# ── Helper: check if GitLab container is running ──
gitlab_running() {
    docker inspect --format='{{.State.Running}}' gitlab 2>/dev/null | grep -q true
}

# ── Helper: wait for GitLab healthy ──
wait_healthy() {
    info "Waiting for GitLab to initialise (this takes 3-5 minutes)..."
    SECONDS=0
    MAX_WAIT=600
    while true; do
        STATUS=$(docker inspect --format='{{.State.Health.Status}}' gitlab 2>/dev/null || echo "starting")
        if [[ "${STATUS}" == "healthy" ]]; then
            ok "GitLab is healthy."
            return 0
        fi
        if (( SECONDS > MAX_WAIT )); then
            warn "GitLab has not become healthy after ${MAX_WAIT}s."
            warn "It may still be initialising. Check: docker logs gitlab"
            return 1
        fi
        printf "\r[*] Status: %-12s (%ds elapsed)" "${STATUS}" "${SECONDS}"
        sleep 10
    done
}

# ═════════════════════════════════════════════════════════════════════════════
# 1) Install GitLab
# ═════════════════════════════════════════════════════════════════════════════
do_install() {
    echo ""
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
    fi

    # Patch data directory
    if [[ "${DATA_DIR}" != "${PLACEHOLDER_DIR}" ]]; then
        info "Patching data directory (${PLACEHOLDER_DIR} -> ${DATA_DIR})..."
        sed -i "s|${PLACEHOLDER_DIR}|${DATA_DIR}|g" "${COMPOSE_DIR}/docker-compose.yml"
        ok "Data directory patched."
    fi

    # Pull and deploy
    info "Pulling Docker images (this may take a few minutes)..."
    cd "${COMPOSE_DIR}"
    docker compose pull
    ok "Images pulled."

    info "Starting GitLab..."
    docker compose up -d
    ok "Containers started."

    # Wait for healthy
    wait_healthy
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
    echo "  Run this script again for post-install tasks:"
    echo "    - Update default email"
    echo "    - Register CI runner"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# 2) Update default email
# ═════════════════════════════════════════════════════════════════════════════
do_update_email() {
    gitlab_running || fail "GitLab container is not running. Install first."

    echo ""
    read -rp "[?] Username to update (default: root): " USERNAME
    USERNAME="${USERNAME:-root}"

    read -rp "[?] New email address: " NEW_EMAIL
    [[ -n "${NEW_EMAIL}" ]] || fail "Email cannot be empty."

    info "Updating email for '${USERNAME}' to '${NEW_EMAIL}'..."
    docker exec -i gitlab gitlab-rails runner "
        user = User.find_by_username('${USERNAME}')
        abort 'User not found' unless user
        user.email = '${NEW_EMAIL}'
        user.skip_reconfirmation!
        user.save!
        puts 'Email updated successfully'
    "
    ok "Email for '${USERNAME}' set to '${NEW_EMAIL}'."
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# 3) Register runner
# ═════════════════════════════════════════════════════════════════════════════
do_register_runner() {
    gitlab_running || fail "GitLab container is not running. Install first."

    echo ""
    echo "  To get a runner token:"
    echo "    GitLab > Admin > CI/CD > Runners > New instance runner"
    echo "    Create a tag > Create Runner > copy the glrt-<token>"
    echo ""
    read -rp "[?] Runner token (glrt-...): " RUNNER_TOKEN
    [[ -n "${RUNNER_TOKEN}" ]] || fail "Token cannot be empty."

    read -rp "[?] Runner description (default: gitlab-runner): " RUNNER_DESC
    RUNNER_DESC="${RUNNER_DESC:-gitlab-runner}"

    read -rp "[?] Default Docker image (default: docker:latest): " RUNNER_IMAGE
    RUNNER_IMAGE="${RUNNER_IMAGE:-docker:latest}"

    info "Registering runner..."
    docker exec -i gitlab-runner gitlab-runner register \
        --non-interactive \
        --url "http://gitlab:80" \
        --token "${RUNNER_TOKEN}" \
        --description "${RUNNER_DESC}" \
        --executor docker \
        --docker-image "${RUNNER_IMAGE}" \
        --docker-privileged \
        --docker-volumes "/var/run/docker.sock:/var/run/docker.sock"

    ok "Runner '${RUNNER_DESC}' registered."

    info "Restarting runner..."
    docker restart gitlab-runner > /dev/null 2>&1
    ok "Runner restarted."
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# 4) Show status
# ═════════════════════════════════════════════════════════════════════════════
do_status() {
    echo ""
    echo "GitLab Status"
    echo "================================================="
    echo ""

    # Container status
    for CTR in gitlab gitlab-runner; do
        if docker inspect --format='{{.State.Running}}' "${CTR}" 2>/dev/null | grep -q true; then
            HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "${CTR}" 2>/dev/null || echo "n/a")
            echo "  ${CTR}        running (${HEALTH})"
        else
            echo "  ${CTR}        stopped"
        fi
    done
    echo ""

    # URLs
    echo "  Web UI          http://${GITLAB_HOST}:3028"
    echo "  SSH clone       ssh://git@${GITLAB_HOST}:2224"
    echo "  Registry        http://${GITLAB_HOST}:5050"
    echo "  Pages           http://${GITLAB_HOST}:8090"
    echo ""

    # Root password
    if docker exec gitlab test -f /etc/gitlab/initial_root_password 2>/dev/null; then
        ROOT_PW=$(docker exec gitlab cat /etc/gitlab/initial_root_password 2>/dev/null \
            | grep "^Password:" | awk '{print $2}')
        echo "  Root password   ${ROOT_PW}"
    else
        echo "  Root password   (initial password file expired or removed)"
    fi

    echo "  Data directory  ${DATA_DIR}"
    echo "  Compose file    ${COMPOSE_DIR}/docker-compose.yml"
    echo ""
    echo "  To stop:    cd ${COMPOSE_DIR} && docker compose down"
    echo "  To restart: cd ${COMPOSE_DIR} && docker compose up -d"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# 5) Upgrade GitLab
# ═════════════════════════════════════════════════════════════════════════════
do_upgrade() {
    gitlab_running || fail "GitLab container is not running. Nothing to upgrade."

    # Get current version
    CURRENT_VER=$(docker exec gitlab cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "unknown")
    info "Current GitLab version: ${CURRENT_VER}"
    echo ""

    # Backup secrets and config
    BACKUP_DIR="${DATA_DIR}/backups/pre-upgrade-$(date +%Y%m%d-%H%M%S)"
    info "Backing up secrets and config to ${BACKUP_DIR}..."
    mkdir -p "${BACKUP_DIR}"
    cp -a "${DATA_DIR}/config/gitlab-secrets.json" "${BACKUP_DIR}/" 2>/dev/null && ok "gitlab-secrets.json backed up." || warn "gitlab-secrets.json not found (first install?)."
    cp -a "${DATA_DIR}/config/gitlab.rb" "${BACKUP_DIR}/" 2>/dev/null && ok "gitlab.rb backed up." || warn "gitlab.rb not found."
    ok "Backup saved to ${BACKUP_DIR}"
    echo ""

    # Optional: create application backup
    read -rp "[?] Create full application backup? This takes a few minutes (y/N): " DO_FULL_BACKUP
    if [[ "${DO_FULL_BACKUP,,}" == "y" ]]; then
        info "Creating application backup (this may take a while)..."
        docker exec gitlab gitlab-backup create STRATEGY=copy 2>&1 | tail -5
        ok "Application backup created in ${DATA_DIR}/data/backups/"
        echo ""
    fi

    # Pull and recreate
    info "Pulling latest images..."
    cd "${COMPOSE_DIR}"
    docker compose pull
    ok "Images pulled."

    info "Recreating containers..."
    docker compose up -d
    ok "Containers recreated."

    # Wait for healthy
    wait_healthy
    echo ""

    # Show new version
    NEW_VER=$(docker exec gitlab cat /opt/gitlab/embedded/service/gitlab-rails/VERSION 2>/dev/null || echo "unknown")

    echo ""
    echo "Upgrade Complete"
    echo "================================================="
    echo ""
    echo "  Previous version  ${CURRENT_VER}"
    echo "  Current version   ${NEW_VER}"
    echo "  Backup location   ${BACKUP_DIR}"
    echo ""
    echo "  If something went wrong, restore secrets with:"
    echo "    cp ${BACKUP_DIR}/gitlab-secrets.json ${DATA_DIR}/config/"
    echo "    cd ${COMPOSE_DIR} && docker compose restart"
    echo ""
}

# ═════════════════════════════════════════════════════════════════════════════
# Main menu
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "GitLab CE - Setup & Management"
echo "================================================="
echo ""
echo "  1) Install GitLab"
echo "  2) Update default email"
echo "  3) Register runner"
echo "  4) Show status"
echo "  5) Upgrade GitLab"
echo ""
read -rp "Select an option [1-5]: " CHOICE

case "${CHOICE}" in
    1) do_install ;;
    2) do_update_email ;;
    3) do_register_runner ;;
    4) do_status ;;
    5) do_upgrade ;;
    *) fail "Invalid option: ${CHOICE}" ;;
esac