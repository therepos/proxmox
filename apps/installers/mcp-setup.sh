#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/mcp-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall an MCP server that exposes a shared folder to Claude
# =============================================================================
# Runs ON THE PROXMOX HOST as a hardened systemd service (mcp-fs). Claude.ai,
# Claude Desktop and Claude Code connect over Streamable HTTP. Reach it from
# outside your LAN through the existing Cloudflare Tunnel (cloudflared-setup.sh).
#
#   Endpoint  http://<host-ip>:<port>/<TOKEN>/mcp
#   Server    apps/mcp/server.py (downloaded from this repo)
# =============================================================================

set -euo pipefail

LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/mcp-install-$(date +%F).log"
mkdir -p "$LOG_DIR"; : >"$LOG_FILE"; chmod 0600 "$LOG_FILE"
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

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

hr() { echo "----------------------------------------------------------------"; }

# --- Config ------------------------------------------------------------------
SHARE_PATH_DEFAULT="${SHARE_PATH:-/mnt/sec/media/shared}"
PORT_DEFAULT="${MCP_PORT:-8765}"
NAME_DEFAULT="${MCP_NAME:-shared-drive}"

SERVICE="mcp-fs"
INSTALL_DIR="/opt/mcp-fs"
CONF_DIR="/etc/mcp-fs"
ENV_FILE="${CONF_DIR}/env"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
REPO_REF="${REPO_REF:-main}"
SERVER_URL="https://github.com/therepos/proxmox/raw/${REPO_REF}/apps/mcp/server.py"
MCP_SERVER_SRC="${MCP_SERVER_SRC:-}"   # optional: local path to server.py (skips download)
PIP_SPEC='mcp>=2,<3'

# --- Preflight ---------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || fail "Run as root on the Proxmox host."; }

ensure_host_deps() {
    local missing=()
    command -v curl    >/dev/null || missing+=(curl)
    command -v python3 >/dev/null || missing+=(python3)
    python3 -c 'import venv, ensurepip' 2>/dev/null || missing+=(python3-venv)
    if (( ${#missing[@]} )); then
        info "Installing host prerequisites: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
            || fail "Could not install: ${missing[*]}"
    fi
    local pyver
    pyver=$(python3 -c 'import sys; print(sys.version_info >= (3, 10))')
    [[ "$pyver" == "True" ]] || fail "Python 3.10+ required (found $(python3 --version))."
}

host_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

load_env() {
    # Exposes MCP_* from the env file into this shell (no-op if not installed).
    [[ -f "$ENV_FILE" ]] || return 1
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
}

is_installed() { [[ -f "$UNIT_FILE" && -f "$ENV_FILE" ]]; }

# --- Pieces ------------------------------------------------------------------
fetch_server() {
    mkdir -p "$INSTALL_DIR"
    if [[ -n "$MCP_SERVER_SRC" ]]; then
        [[ -f "$MCP_SERVER_SRC" ]] || fail "MCP_SERVER_SRC not found: $MCP_SERVER_SRC"
        install -m 0644 "$MCP_SERVER_SRC" "${INSTALL_DIR}/server.py"
        info "Using local server.py from $MCP_SERVER_SRC"
    else
        curl -fsSL "${SERVER_URL}?$(date +%s)" -o "${INSTALL_DIR}/server.py.new" \
            || fail "Download failed: $SERVER_URL"
        mv "${INSTALL_DIR}/server.py.new" "${INSTALL_DIR}/server.py"
        chmod 0644 "${INSTALL_DIR}/server.py"
    fi
    python3 -m py_compile "${INSTALL_DIR}/server.py" || fail "server.py does not compile."
}

setup_venv() {
    if [[ ! -x "${INSTALL_DIR}/venv/bin/python" ]]; then
        info "Creating Python environment..."
        python3 -m venv "${INSTALL_DIR}/venv" || fail "venv creation failed."
    fi
    info "Installing MCP SDK (pip)..."
    "${INSTALL_DIR}/venv/bin/pip" install -q --upgrade pip >/dev/null 2>&1 || true
    "${INSTALL_DIR}/venv/bin/pip" install -q --upgrade "$PIP_SPEC" uvicorn >/dev/null 2>&1 \
        || fail "pip install failed. See $LOG_FILE"
    "${INSTALL_DIR}/venv/bin/python" -c 'import mcp, uvicorn' || fail "MCP SDK import failed."
    rm -rf "${INSTALL_DIR}/venv/lib"/python*/site-packages/pip/__pycache__ 2>/dev/null || true
}

write_env() {
    # $1 share  $2 port  $3 read_only(0/1)  $4 name  $5 token  $6 public_url
    mkdir -p "$CONF_DIR"; chmod 0700 "$CONF_DIR"
    umask 077
    cat > "$ENV_FILE" <<EOF
MCP_ROOT=$1
MCP_PORT=$2
MCP_HOST=0.0.0.0
MCP_READ_ONLY=$3
MCP_NAME=$4
MCP_TOKEN=$5
MCP_PUBLIC_URL=$6
PYTHONDONTWRITEBYTECODE=1
PYTHONUNBUFFERED=1
EOF
    chmod 0600 "$ENV_FILE"
    umask 022
}

write_unit() {
    # $1 share  $2 read_only(0/1)
    local share="$1" ro="$2" access
    if [[ "$ro" == "1" ]]; then access="ReadOnlyPaths=${share}"; else access="ReadWritePaths=${share}"; fi
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=MCP filesystem server for Claude (${share})
After=network-online.target
Wants=network-online.target
RequiresMountsFor=${share}

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/server.py
Restart=on-failure
RestartSec=5
UMask=0002

# Sandbox: the whole host is read-only to this process except the share.
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_DAC_OVERRIDE CAP_DAC_READ_SEARCH CAP_CHOWN CAP_FOWNER
InaccessiblePaths=-/etc/pve -/var/lib/vz -/etc/ssh
${access}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

smoke_test() {
    # $1 port  $2 token
    local port="$1" token="$2" i body
    for i in $(seq 1 15); do
        curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS --max-time 2 "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 \
        || { journalctl -u "$SERVICE" --no-pager -n 20; fail "Service did not come up. See above."; }
    body=$(curl -fsS --max-time 5 -X POST "http://127.0.0.1:${port}/${token}/mcp" \
        -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"mcp-setup","version":"1"}}}' 2>/dev/null || true)
    grep -q '"serverInfo"' <<<"$body" || { echo "$body" | head -c 400; echo; fail "MCP handshake failed."; }
    # Wrong token must be a plain 404, not an OAuth challenge.
    [[ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:${port}/mcp")" == "404" ]] \
        || warn "Unauthenticated request did not return 404. Check the token gate."
    ok "MCP handshake OK."
}

print_connect() {
    load_env || return 0
    local ip; ip="$(host_ip)"
    local lan="http://${ip}:${MCP_PORT}/${MCP_TOKEN}/mcp"
    local pub=""
    [[ -n "${MCP_PUBLIC_URL:-}" ]] && pub="${MCP_PUBLIC_URL%/}/${MCP_TOKEN}/mcp"
    echo ""
    hr
    echo "  CONNECT CLAUDE TO:  ${MCP_ROOT}  ($( [[ "$MCP_READ_ONLY" == "1" ]] && echo read-only || echo read/write ))"
    hr
    echo ""
    echo "  LAN URL     : ${lan}"
    if [[ -n "$pub" ]]; then
        echo "  Public URL  : ${pub}"
    else
        echo "  Public URL  : (not set - see step 1 below)"
    fi
    echo ""
    echo "  1) Expose through your Cloudflare Tunnel (once):"
    echo "       Zero Trust -> Networks -> Tunnels -> <your tunnel> -> Public Hostname -> Add"
    echo "       Subdomain: mcp   Domain: <yours>   Type: HTTP   URL: ${ip}:${MCP_PORT}"
    echo "       Then re-run this script -> option 4 to save the hostname."
    echo ""
    echo "  2) claude.ai / Claude Desktop:"
    echo "       Settings -> Connectors -> Add custom connector"
    echo "       Name: ${MCP_NAME}    URL: ${pub:-https://mcp.<your-domain>/${MCP_TOKEN}/mcp}"
    echo "       Leave OAuth fields empty. The secret is in the URL."
    echo ""
    echo "  3) Claude Code (any machine that can reach the URL):"
    echo "       claude mcp add --transport http ${MCP_NAME} ${pub:-$lan}"
    echo ""
    echo "  Treat the URL like a password. Option 5 rotates it."
    echo ""
}

# --- Actions -----------------------------------------------------------------
action_install() {
    require_root
    command -v systemctl >/dev/null || fail "systemd required."
    ensure_host_deps

    if is_installed; then
        warn "Already installed. Reinstalling replaces the service and issues a NEW token."
        local c; read -p "  Continue? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
        systemctl stop "$SERVICE" 2>/dev/null || true
    fi

    hr; echo "  Setup"; hr
    local share port ro name pub
    read -p "  Folder to expose [${SHARE_PATH_DEFAULT}]: " share </dev/tty
    share="${share:-$SHARE_PATH_DEFAULT}"
    share="$(readlink -f "$share")" || true
    [[ -d "$share" ]] || fail "Not a directory: $share"
    [[ "$share" != "/" ]] || fail "Refusing to expose the root filesystem."

    read -p "  Listen port [${PORT_DEFAULT}]: " port </dev/tty
    port="${port:-$PORT_DEFAULT}"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || fail "Port must be 1024-65535."
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
        is_installed || fail "Port ${port} is already in use."
    fi

    echo ""
    echo "  Access level:"
    echo "    1) Read and write  (Claude can create, edit, move, delete files)"
    echo "    2) Read-only"
    local c; read -p "  Select [1]: " c </dev/tty
    case "${c:-1}" in 1) ro=0 ;; 2) ro=1 ;; *) fail "Invalid choice." ;; esac

    read -p "  Connector name shown in Claude [${NAME_DEFAULT}]: " name </dev/tty
    name="${name:-$NAME_DEFAULT}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Name may only contain letters, digits, . _ -"

    echo ""
    echo "  Public hostname (optional). If you already added a Cloudflare public"
    echo "  hostname for this service, enter it so the full URL is printed."
    read -p "  Public URL, e.g. https://mcp.example.com [skip]: " pub </dev/tty
    pub="${pub:-}"
    [[ -z "$pub" || "$pub" =~ ^https?:// ]] || fail "Public URL must start with http:// or https://"

    echo ""
    echo "  Folder  : $share"
    echo "  Port    : $port"
    echo "  Access  : $( [[ "$ro" == "1" ]] && echo read-only || echo read/write )"
    echo "  Name    : $name"
    echo "  Service : $SERVICE (systemd, sandboxed, runs on this host)"
    echo ""
    read -p "  Proceed? [Y/n]: " c </dev/tty
    [[ "$c" =~ ^[Nn]$ ]] && fail "Cancelled."

    local token; token="$(openssl rand -hex 24)"

    fetch_server
    setup_venv
    write_env "$share" "$port" "$ro" "$name" "$token" "$pub"
    write_unit "$share" "$ro"
    systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
    smoke_test "$port" "$token"

    echo ""
    ok "MCP server installed and running."
    print_connect
    echo "  Log file : ${LOG_FILE}"
    echo ""
}

action_status() {
    is_installed || { info "Not installed."; return; }
    load_env
    echo ""
    echo "  Service : $SERVICE  [$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)]"
    echo "  Folder  : $MCP_ROOT"
    echo "  Port    : $MCP_PORT"
    echo "  Access  : $( [[ "$MCP_READ_ONLY" == "1" ]] && echo read-only || echo read/write )"
    echo -n "  Health  : "
    curl -fsS --max-time 3 "http://127.0.0.1:${MCP_PORT}/healthz" 2>/dev/null || echo "(no response)"
    echo ""
    echo -n "  SDK     : "
    "${INSTALL_DIR}/venv/bin/pip" show mcp 2>/dev/null | awk '/^Version/ {print $2}' || echo "unknown"
    echo ""
    echo "  Recent logs:"
    journalctl -u "$SERVICE" --no-pager -n 8 2>/dev/null | sed 's/^/    /' || true
    print_connect
}

action_set_public_url() {
    require_root
    is_installed || fail "Not installed."
    load_env
    local pub
    echo "  Current public URL: ${MCP_PUBLIC_URL:-(none)}"
    read -p "  New public URL, e.g. https://mcp.example.com (empty to clear): " pub </dev/tty
    [[ -z "$pub" || "$pub" =~ ^https?:// ]] || fail "Must start with http:// or https://"
    write_env "$MCP_ROOT" "$MCP_PORT" "$MCP_READ_ONLY" "$MCP_NAME" "$MCP_TOKEN" "$pub"
    ok "Saved."
    print_connect
}

action_rotate() {
    require_root
    is_installed || fail "Not installed."
    load_env
    echo "  This invalidates the current URL. Every Claude client must be re-added."
    local c; read -p "  Rotate token? [y/N]: " c </dev/tty
    [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
    local token; token="$(openssl rand -hex 24)"
    write_env "$MCP_ROOT" "$MCP_PORT" "$MCP_READ_ONLY" "$MCP_NAME" "$token" "${MCP_PUBLIC_URL:-}"
    systemctl restart "$SERVICE"
    smoke_test "$MCP_PORT" "$token"
    ok "Token rotated."
    print_connect
}

action_update() {
    require_root
    is_installed || fail "Not installed."
    load_env
    ensure_host_deps
    cp -a "${INSTALL_DIR}/server.py" "${INSTALL_DIR}/server.py.bak" 2>/dev/null || true
    fetch_server
    setup_venv
    systemctl restart "$SERVICE"
    if smoke_test "$MCP_PORT" "$MCP_TOKEN"; then
        rm -f "${INSTALL_DIR}/server.py.bak"
        ok "Updated."
    fi
}

action_logs() {
    is_installed || fail "Not installed."
    echo "  Live logs. Press Ctrl+C to stop."
    journalctl -u "$SERVICE" -n 50 -f
}

action_uninstall() {
    require_root
    is_installed || fail "Not installed."
    load_env
    echo "  Removes the service, the Python environment and the saved token."
    echo "  The folder ${MCP_ROOT} is NOT touched."
    local c; read -p "  Type 'yes' to confirm: " c </dev/tty
    [[ "$c" == "yes" ]] || { info "Cancelled."; exit 0; }
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT_FILE"
    systemctl daemon-reload
    rm -rf "$INSTALL_DIR" "$CONF_DIR"
    ok "Removed. Delete the connector in claude.ai (Settings -> Connectors) and the"
    echo "       Cloudflare public hostname if you no longer need them."
}

# --- Menu --------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  MCP Shared Folder - Claude Connector"
echo "================================================================"
echo ""
if is_installed; then
    ok "Installed  [$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)]"
else
    info "Not installed"
    echo ""
    echo "  Lets Claude (claude.ai, Desktop, Claude Code) browse, search,"
    echo "  read and optionally write files in one folder on this host."
fi
echo ""
echo "  1) Install / Reinstall"
echo "  2) Show status and connection URL"
echo "  3) View logs"
echo "  4) Set public URL (Cloudflare hostname)"
echo "  5) Rotate token"
echo "  6) Update server"
echo "  7) Uninstall"
echo "  q) Quit"
echo ""
read -p "Select an option: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_status ;;
    3) action_logs ;;
    4) action_set_public_url ;;
    5) action_rotate ;;
    6) action_update ;;
    7) action_uninstall ;;
    q|Q) info "Bye."; exit 0 ;;
    *) fail "Invalid option." ;;
esac
