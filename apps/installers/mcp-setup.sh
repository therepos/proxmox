#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/mcp-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall MCP servers (apps/mcp) that connect Claude to this host
# =============================================================================
# One installer for every server under apps/mcp/<id>/. Each server becomes its
# own hardened systemd unit on the Proxmox host:
#
#   /opt/mcp/<id>/{venv,server.py,common.py,<extra files>}
#   /etc/mcp/<id>.env                      settings + token (mode 600)
#   /etc/systemd/system/<id>.service
#   http://<host-ip>:<port>/<TOKEN>/mcp    endpoint (see apps/mcp/common.py)
#
# Adding a server: drop apps/mcp/<id>/server.py in the repo, then add one line
# to the SERVERS registry below and, if it needs its own prompts, a
# configure_<id>() function (see configure_mcpshared). Servers with more than
# one .py file list them in FILES_<id>; extra pip packages go in PIP_<id>.
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

# --- Registry ----------------------------------------------------------------
# id | default port | one-line description
# id is ONE lowercase word (letters/digits, no separators) and is the name used
# everywhere: repo folder, /opt/mcp/<id>, /etc/mcp/<id>.env, <id>.service,
# configure_<id>(), the Cloudflare subdomain and the connector name in Claude.
SERVERS=(
    "mcpshared|8765|Browse, search, read, write and extract text from files in one folder on this host"
)
# Per-server extras (optional): additional files next to server.py, extra pip packages.
FILES_mcpshared="extraction_tools.py transfer.py build_tools.py"
PIP_mcpshared="openpyxl pdfplumber python-docx python-pptx reportlab"

# --- Paths -------------------------------------------------------------------
BASE_DIR="/opt/mcp"
CONF_DIR="/etc/mcp"
REPO_REF="${REPO_REF:-main}"
RAW_BASE="https://github.com/therepos/proxmox/raw/${REPO_REF}/apps/mcp"
MCP_SRC_DIR="${MCP_SRC_DIR:-}"     # optional: local checkout of apps/mcp (skips download)
PIP_SPEC='mcp>=2,<3'

# Set by select_server()
ID=""; DEFAULT_PORT=""; DESC=""
INSTALL_DIR=""; ENV_FILE=""; UNIT_FILE=""; SERVICE=""

# Filled by configure_<id>() during install
EXTRA_ENV=""        # extra KEY=VALUE lines for the env file
RW_PATHS=""         # space-separated paths the unit may write
RO_PATHS=""         # space-separated paths the unit may only read
SUMMARY=""          # lines shown in the confirm step
CONNECT_NOTE=""     # one line shown with the connect instructions

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
    [[ "$(python3 -c 'import sys; print(sys.version_info >= (3, 10))')" == "True" ]] \
        || fail "Python 3.10+ required (found $(python3 --version))."
}

host_ip() { hostname -I 2>/dev/null | awk '{print $1}'; }

is_installed() { [[ -f "$UNIT_FILE" && -f "$ENV_FILE" ]]; }

load_env() {
    [[ -f "$ENV_FILE" ]] || return 1
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
}

svc_state() {
    # is-active prints inactive/failed AND exits non-zero, so capture rather than || fallback
    [[ -f "/etc/systemd/system/$1.service" ]] || { echo "not installed"; return; }
    systemctl is-active "$1" 2>/dev/null || true
}

# --- Server selection --------------------------------------------------------
select_server() {
    local entries=("${SERVERS[@]}") i=1 e id port desc c
    echo "  Available MCP servers:"
    echo ""
    for e in "${entries[@]}"; do
        IFS='|' read -r id port desc <<<"$e"
        printf '    %d) %s\n' "$i" "$id"
        i=$((i + 1))
    done
    echo ""
    echo "    q) Quit"
    echo ""
    read -p "  Select a server: " c </dev/tty
    case "$c" in q|Q) info "Bye."; exit 0 ;; esac
    [[ "$c" =~ ^[0-9]+$ && "$c" -ge 1 && "$c" -le ${#entries[@]} ]] || fail "Invalid choice."
    IFS='|' read -r ID DEFAULT_PORT DESC <<<"${entries[$((c - 1))]}"
    [[ "$ID" =~ ^[a-z0-9]+$ ]] || fail "Server id '${ID}' must be one lowercase word (letters/digits)."
    INSTALL_DIR="${BASE_DIR}/${ID}"
    ENV_FILE="${CONF_DIR}/${ID}.env"
    SERVICE="${ID}"
    UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
}

# --- Per-server configuration ------------------------------------------------
# Each configure_<id> asks its questions and fills EXTRA_ENV / RW_PATHS /
# RO_PATHS / SUMMARY / CONNECT_NOTE. Common items (port, name, token, public
# URL) are handled by action_install.

configure_mcpshared() {
    local share ro c
    read -p "  Folder to expose [${SHARE_PATH:-/mnt/sec/media/shared}]: " share </dev/tty
    share="${share:-${SHARE_PATH:-/mnt/sec/media/shared}}"
    share="$(readlink -f "$share")" || true
    [[ -d "$share" ]] || fail "Not a directory: $share"
    [[ "$share" != "/" ]] || fail "Refusing to expose the root filesystem."

    echo ""
    echo "  Access level:"
    echo "    1) Read and write  (Claude can create, edit, move, delete files)"
    echo "    2) Read-only"
    read -p "  Select [1]: " c </dev/tty
    case "${c:-1}" in 1) ro=0 ;; 2) ro=1 ;; *) fail "Invalid choice." ;; esac

    EXTRA_ENV="MCP_ROOT=${share}
MCP_READ_ONLY=${ro}"
    if [[ "$ro" == "1" ]]; then RO_PATHS="$share"; else RW_PATHS="$share"; fi
    SUMMARY="  Folder  : ${share}
  Access  : $( [[ "$ro" == "1" ]] && echo read-only || echo read/write )"
    CONNECT_NOTE="Folder ${share} ($( [[ "$ro" == "1" ]] && echo read-only || echo read/write ))"
}

# --- Pieces ------------------------------------------------------------------
server_extra() {
    # $1 = FILES or PIP: echo the per-server list, empty if unset
    local var="${1}_${ID}"
    echo "${!var:-}"
}

fetch_files() {
    mkdir -p "$INSTALL_DIR"
    local f src extra files=("common.py" "${ID}/server.py")
    for extra in $(server_extra FILES); do files+=("${ID}/${extra}"); done
    for f in "${files[@]}"; do
        local dst="${INSTALL_DIR}/$(basename "$f")"
        if [[ -n "$MCP_SRC_DIR" ]]; then
            src="${MCP_SRC_DIR}/${f}"
            [[ -f "$src" ]] || fail "Not found: $src"
            install -m 0644 "$src" "$dst"
        else
            curl -fsSL "${RAW_BASE}/${f}?$(date +%s)" -o "${dst}.new" || fail "Download failed: ${RAW_BASE}/${f}"
            mv "${dst}.new" "$dst"; chmod 0644 "$dst"
        fi
        python3 -m py_compile "$dst" || fail "$(basename "$f") does not compile."
    done
    rm -rf "${INSTALL_DIR}/__pycache__"
    [[ -n "$MCP_SRC_DIR" ]] && info "Using local files from $MCP_SRC_DIR" || true
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
    local extra; extra="$(server_extra PIP)"
    if [[ -n "$extra" ]]; then
        info "Installing extras for ${ID}: ${extra}"
        # shellcheck disable=SC2086
        "${INSTALL_DIR}/venv/bin/pip" install -q --upgrade $extra >/dev/null 2>&1 \
            || warn "Extras failed to install; tools that need them will say so. See $LOG_FILE"
    fi
}

write_env() {
    # $1 port  $2 name  $3 token  $4 public_url  $5 extra lines
    mkdir -p "$CONF_DIR"; chmod 0700 "$CONF_DIR"
    umask 077
    {
        echo "MCP_ID=${ID}"
        echo "MCP_PORT=$1"
        echo "MCP_HOST=0.0.0.0"
        echo "MCP_NAME=$2"
        echo "MCP_TOKEN=$3"
        echo "MCP_PUBLIC_URL=$4"
        echo "MCP_RW_PATHS=${RW_PATHS}"
        echo "MCP_RO_PATHS=${RO_PATHS}"
        echo "PYTHONDONTWRITEBYTECODE=1"
        echo "PYTHONUNBUFFERED=1"
        [[ -n "$5" ]] && echo "$5"
    } > "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
    umask 022
}

write_unit() {
    local mounts="" access="" p
    for p in $RW_PATHS; do access+="ReadWritePaths=${p}"$'\n'; mounts+=" ${p}"; done
    for p in $RO_PATHS; do access+="ReadOnlyPaths=${p}"$'\n';  mounts+=" ${p}"; done
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=MCP server for Claude: ${ID}
After=network-online.target
Wants=network-online.target
${mounts:+RequiresMountsFor=${mounts# }}

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALL_DIR}/venv/bin/python ${INSTALL_DIR}/server.py
Restart=on-failure
RestartSec=5
UMask=0002

# Sandbox: the whole host is read-only to this process except paths listed below.
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
    echo "  CONNECT CLAUDE TO: ${MCP_NAME}"
    [[ -n "$CONNECT_NOTE" ]] && echo "  ${CONNECT_NOTE}"
    hr
    echo ""
    echo "  LAN URL     : ${lan}"
    if [[ -n "$pub" ]]; then
        echo "  Public URL  : ${pub}"
    else
        echo "  Public URL  : (not set - see step 1 below)"
    fi
    echo ""
    echo "  1) Expose through your Cloudflare Tunnel (once per server):"
    echo "       Zero Trust -> Networks -> Tunnels -> <your tunnel> -> Public Hostname -> Add"
    echo "       Subdomain: ${ID}   Domain: <yours>   Type: HTTP   URL: ${ip}:${MCP_PORT}"
    echo "       Then re-run this script -> option 4 to save the hostname."
    echo ""
    echo "  2) claude.ai / Claude Desktop:"
    echo "       Settings -> Connectors -> Add custom connector"
    echo "       Name: ${MCP_NAME}    URL: ${pub:-https://${ID}.<your-domain>/${MCP_TOKEN}/mcp}"
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
        warn "'${ID}' is already installed. Reinstalling replaces the service and issues a NEW token."
        local c; read -p "  Continue? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
        systemctl stop "$SERVICE" 2>/dev/null || true
    fi

    hr; echo "  Setup: ${ID}"; hr
    local port name pub c

    # Server-specific questions
    if declare -F "configure_${ID}" >/dev/null; then
        "configure_${ID}"
        echo ""
    fi

    read -p "  Listen port [${DEFAULT_PORT}]: " port </dev/tty
    port="${port:-$DEFAULT_PORT}"
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1024 && "$port" -le 65535 ]] || fail "Port must be 1024-65535."
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${port}\$"; then
        is_installed || fail "Port ${port} is already in use."
    fi

    read -p "  Connector name shown in Claude [${ID}]: " name </dev/tty
    name="${name:-$ID}"
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Name may only contain letters, digits, . _ -"

    echo ""
    echo "  Public hostname (optional). If you already added a Cloudflare public"
    echo "  hostname for this server, enter it so the full URL is printed."
    read -p "  Public URL, e.g. https://mcp.example.com [skip]: " pub </dev/tty
    pub="${pub:-}"
    [[ -z "$pub" || "$pub" =~ ^https?:// ]] || fail "Public URL must start with http:// or https://"

    echo ""
    echo "  Server  : ${ID}"
    [[ -n "$SUMMARY" ]] && echo "$SUMMARY"
    echo "  Port    : $port"
    echo "  Name    : $name"
    echo "  Service : $SERVICE (systemd, sandboxed, runs on this host)"
    echo ""
    read -p "  Proceed? [Y/n]: " c </dev/tty
    [[ "$c" =~ ^[Nn]$ ]] && fail "Cancelled."

    local token; token="$(openssl rand -hex 24)"

    fetch_files
    setup_venv
    write_env "$port" "$name" "$token" "$pub" "$EXTRA_ENV"
    write_unit
    systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    systemctl restart "$SERVICE"
    smoke_test "$port" "$token"

    echo ""
    ok "'${ID}' installed and running."
    print_connect
    echo "  Log file : ${LOG_FILE}"
    echo ""
}

action_status() {
    is_installed || { info "'${ID}' is not installed."; return; }
    load_env
    echo ""
    echo "  Service : $SERVICE  [$(systemctl is-active "$SERVICE" 2>/dev/null || echo unknown)]"
    echo "  Port    : $MCP_PORT"
    [[ -n "${MCP_RW_PATHS:-}" ]] && echo "  Writes  : $MCP_RW_PATHS"
    [[ -n "${MCP_RO_PATHS:-}" ]] && echo "  Reads   : $MCP_RO_PATHS"
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
    is_installed || fail "'${ID}' is not installed."
    load_env
    local pub
    echo "  Current public URL: ${MCP_PUBLIC_URL:-(none)}"
    read -p "  New public URL, e.g. https://mcp.example.com (empty to clear): " pub </dev/tty
    [[ -z "$pub" || "$pub" =~ ^https?:// ]] || fail "Must start with http:// or https://"
    sed -i "s|^MCP_PUBLIC_URL=.*|MCP_PUBLIC_URL=${pub}|" "$ENV_FILE"
    ok "Saved."
    print_connect
}

action_rotate() {
    require_root
    is_installed || fail "'${ID}' is not installed."
    load_env
    echo "  This invalidates the current URL. Every Claude client must be re-added."
    local c; read -p "  Rotate token? [y/N]: " c </dev/tty
    [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
    local token; token="$(openssl rand -hex 24)"
    sed -i "s|^MCP_TOKEN=.*|MCP_TOKEN=${token}|" "$ENV_FILE"
    systemctl restart "$SERVICE"
    smoke_test "$MCP_PORT" "$token"
    ok "Token rotated."
    print_connect
}

action_update() {
    require_root
    is_installed || fail "'${ID}' is not installed."
    load_env
    ensure_host_deps
    fetch_files
    setup_venv
    systemctl restart "$SERVICE"
    smoke_test "$MCP_PORT" "$MCP_TOKEN"
    ok "'${ID}' updated."
}

action_logs() {
    is_installed || fail "'${ID}' is not installed."
    echo "  Live logs. Press Ctrl+C to stop."
    journalctl -u "$SERVICE" -n 50 -f
}

action_uninstall() {
    require_root
    is_installed || fail "'${ID}' is not installed."
    load_env
    echo "  Removes the '${ID}' service, its Python environment and saved token."
    echo "  Data it served is NOT touched."
    local c; read -p "  Type 'yes' to confirm: " c </dev/tty
    [[ "$c" == "yes" ]] || { info "Cancelled."; exit 0; }
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT_FILE" "$ENV_FILE"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload
    rmdir "$BASE_DIR" "$CONF_DIR" 2>/dev/null || true
    ok "Removed. Delete the connector in claude.ai (Settings -> Connectors) and the"
    echo "       Cloudflare public hostname if you no longer need them."
}

# --- Menu --------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  MCP Servers - Claude Connectors"
echo "================================================================"
echo ""
select_server
echo ""
echo "  ${ID}: ${DESC}"
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
