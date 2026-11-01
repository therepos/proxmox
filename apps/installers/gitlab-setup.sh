#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/gitlab-setup.sh?$(date +%s))"
# Purpose: Deploys and manages GitLab CE with Runner, Container Registry and Pages (Ubuntu/PVE9)
# =============================================================================
# Usage:
#   1) Install GitLab        - fresh deploy via Docker Compose
#   2) Update default email  - change root user email via Rails console
#   3) Register runner       - register a CI runner with a token
#   4) Show status           - display service health and credentials
#   5) Upgrade GitLab        - backup secrets, pull latest, recreate
#
# Config (env): GITLAB_HOST (default: auto-detected LAN IP),
#   GITLAB_DATA_DIR (default: /mnt/sec/apps/gitlab).
# =============================================================================

set -euo pipefail

# --- Helpers -----------------------------------------------------------------
# >>> ui-block (managed by scripts/sync-ui.sh — do not edit here) >>>
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
# <<< ui-block <<<

# --- Config ------------------------------------------------------------------
PLACEHOLDER_IP="192.168.1.100"
PLACEHOLDER_DIR="/mnt/sec/apps/gitlab"
HOST_IP=$(hostname -I | awk '{print $1}')
GITLAB_HOST="${GITLAB_HOST:-${HOST_IP}}"
DATA_DIR="${GITLAB_DATA_DIR:-/mnt/sec/apps/gitlab}"
COMPOSE_DIR="${DATA_DIR}/compose"

# --- Compose file --------------------------------------------------------------
write_compose(){
cat <<'YML'
# https://docs.gitlab.com/install/docker/installation/
# Post-deploy: wait 3-5 minutes for database initialisation (important)
# Login with username (root) and password (initial_root_password):
#   docker exec gitlab cat /etc/gitlab/initial_root_password
# =====
# Setup Runner:
# 1. GitLab > Admin > CI/CD > Create Instance Runner
# 2. Create a tag > Create Runner
#      docker exec -it gitlab-runner bash
#      gitlab-runner register  --url http://gitlab:80  --token glrt-<token>
#    Use default settings:
#      url:          http://gitlab:80
#      description:  gitlab-runner
#      executor:     docker
#      image:        docker:latest
# 3. Edit configuration at /etc/gitlab-runner/config.toml
#    (host path: /mnt/sec/apps/gitlab/runner/config/config.toml)
#      [runners.docker]
#        image = "docker:latest"
#        privileged = true
#        volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
# 4. Restart runner
#      docker restart gitlab-runner
# =====
# Update Default Email:
# 1. Enter the Rails console
#      docker exec -it gitlab bash
#      gitlab-rails console
# 2. Change username and email
#      user = User.find_by_username('root')
#      user.email = 'your@email.com'
#      user.skip_reconfirmation!
#      user.save!
# 3. Restart GitLab
#      docker exec -it gitlab gitlab-ctl restart
# =====
# Disable Auto DevOps (recommended):
#   Settings > CI/CD > Auto DevOps : Turn Off
# =====
# Pull from Container Registry:
#   docker login <HOST_IP>:5050
#   docker pull <HOST_IP>:5050/username/project:latest
# =====
# Insecure registry (if not using HTTPS):
#   nano /etc/docker/daemon.json
#     { "insecure-registries": ["<HOST_IP>:5050"] }
#   systemctl restart docker
# =====
# Edit defaults below to match your environment:
#   HOST_IP   - your server's LAN IP or hostname
#   Ports     - 3028 (web), 2224 (ssh), 5050 (registry), 8090 (pages)
#   Data      - /mnt/sec/apps/gitlab (persistent storage root)
# =====

services:
  gitlab:
    image: gitlab/gitlab-ce:latest
    container_name: gitlab
    restart: unless-stopped
    hostname: gitlab
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        # External access
        external_url 'http://192.168.1.100:3028'
        nginx['listen_port'] = 80
        nginx['listen_https'] = false

        # SSH
        gitlab_rails['gitlab_shell_ssh_port'] = 2224

        # Container Registry
        registry_external_url 'http://192.168.1.100:5050'
        registry_nginx['listen_port'] = 5050
        registry_nginx['listen_https'] = false

        # GitLab Pages
        pages_external_url 'http://192.168.1.100:8090'
        gitlab_pages['enable'] = true
        gitlab_pages['listen_proxy'] = '0.0.0.0:8090'
        gitlab_pages['external_http'] = ['0.0.0.0:8090']
        pages_nginx['enable'] = false

        # Performance tuning (reduce memory for small instances)
        puma['workers'] = 2
        sidekiq['concurrency'] = 5
        prometheus_monitoring['enable'] = false
    ports:
      - '3028:80'
      - '2224:22'
      - '5050:5050'
      - '8090:8090'
    volumes:
      - /mnt/sec/apps/gitlab/config:/etc/gitlab
      - /mnt/sec/apps/gitlab/logs:/var/log/gitlab
      - /mnt/sec/apps/gitlab/data:/var/opt/gitlab
    shm_size: '256m'
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/-/health"]
      interval: 30s
      timeout: 10s
      retries: 20
      start_period: 300s
    networks:
      - gitlab-net

  gitlab-runner:
    image: gitlab/gitlab-runner:latest
    container_name: gitlab-runner
    restart: unless-stopped
    depends_on:
      gitlab:
        condition: service_healthy
    volumes:
      - /mnt/sec/apps/gitlab/runner/config:/etc/gitlab-runner
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - gitlab-net

networks:
  gitlab-net:
YML
}

# --- Root check --------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# --- Docker check ------------------------------------------------------------
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

    # Write docker-compose.yml (kept in this script so the installer is self-contained)
    info "Writing docker-compose.yml..."
    write_compose > "${COMPOSE_DIR}/docker-compose.yml"
    ok "docker-compose.yml written."

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
# --- Main menu ---------------------------------------------------------------
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
