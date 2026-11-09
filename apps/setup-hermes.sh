#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-hermes.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall Hermes Agent LXC (Docker) on Proxmox
# =============================================================================

set -euo pipefail

LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/hermes-install-$(date +%F).log"
mkdir -p "$LOG_DIR"; : >"$LOG_FILE"; chmod 0644 "$LOG_FILE"
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# --- Helpers -----------------------------------------------------------------
# >>> admonition
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
banner() { local l='================================================='; printf '\n%s\n  %s\n%s\n' "$l" "$*" "$l"; }
# <<< admonition
# >>> menu
menu() {
  local o name desc i=1 w=0 pick
  { true </dev/tty; } 2>/dev/null || { warn "No terminal for the menu."; exit 0; }
  for o in "$@"; do name="${o%%|*}"; (( ${#name} > w )) && w=${#name}; done
  echo ""
  for o in "$@"; do
    name="${o%%|*}"; desc=""; [[ "$o" == *"|"* ]] && desc="${o#*|}"
    if [[ -n "$desc" ]]; then printf '  %d) %-*s  %s\n' "$i" "$w" "$name" "$desc"
    else printf '  %d) %s\n' "$i" "$name"; fi
    i=$((i + 1))
  done
  echo "  0) Exit"
  echo ""
  while true; do
    read -rp "  Choose [0-$#]: " pick </dev/tty || exit 0
    [[ "$pick" == "0" ]] && exit 0
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= $# )); then
      CHOICE="${!pick}"; CHOICE="${CHOICE%%|*}"; return 0
    fi
    warn "Choose a number from 0 to $#."
  done
}
# <<< menu

CYAN="\e[36m"
RESET="\e[0m"

hr() { echo "----------------------------------------------------------------"; }

# --- Config ------------------------------------------------------------------
HOSTNAME="hermes"
CTID_DEFAULT=120
MEMORY=8192
CORES=2
DISK=32
SWAP=2048
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
BRIDGE="vmbr0"
TIMEZONE="$(cat /etc/timezone 2>/dev/null || echo UTC)"

IMAGE="nousresearch/hermes-agent:latest"
DATA_DIR="/opt/hermes"
DASH_PORT=9119
GW_PORT=8642
DASH_BIND="127.0.0.1"
DASH_ENABLE=""
DASH_USER=""
DASH_PASS=""

SANDBOX_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-hermessb.sh"

PAGES_PORT=8088
PAGES_DIR="/opt/hermes-pages"

# Local LLM on the GPU VM (installed by setup-llama.sh). The VM saves its address and
# API key to this file on the shared drive, so this host can connect Hermes with no typing.
LLM_ENV="${LLM_ENV:-/mnt/sec/apps/llama/env}"
LLM_SONNET="claude-sonnet-5-5"
LLM_OPUS="claude-opus-5-5"

PROVIDER_LABEL=""
PROVIDER_ENVVAR=""
PROVIDER_MODEL=""
PROVIDER_KEY=""
TG_TOKEN=""
TG_USERID=""
TG_BOTNAME=""

# --- Preflight ---------------------------------------------------------------
require_root() { [[ $EUID -eq 0 ]] || fail "Run as root on the Proxmox host."; }

ensure_host_deps() {
    local missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v jq   >/dev/null || missing+=(jq)
    if (( ${#missing[@]} )); then
        info "Installing host prerequisites: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 \
            || fail "Could not install: ${missing[*]}. Install them manually and re-run."
    fi
}

preflight() {
    require_root
    command -v pct >/dev/null || fail "pct not found. Run this on the Proxmox host, not inside a VM or LXC."
    ensure_host_deps

    pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$STORAGE" \
        || fail "Storage '$STORAGE' not found. Edit STORAGE near the top of this script."
    pvesm status 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx "$TEMPLATE_STORAGE" \
        || fail "Template storage '$TEMPLATE_STORAGE' not found. Edit TEMPLATE_STORAGE."

    local free_mb
    free_mb=$(free -m | awk '/^Mem:/ {print $7}')
    if (( free_mb < MEMORY )); then
        warn "Only ${free_mb}MB RAM free; this container requests ${MEMORY}MB."
        read -p "  Continue anyway? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || fail "Cancelled."
    fi

    curl -fsS --max-time 10 https://api.telegram.org >/dev/null 2>&1 \
        || warn "Cannot reach api.telegram.org from this host. Check DNS if setup stalls later."

    ok "Preflight checks passed."
}

# --- Guided setup ------------------------------------------------------------
choose_provider() {
    banner "Step 1 of 4 - Choose your AI provider"
    echo ""
    echo "  You need a paid API key from ONE of these providers."
    echo "  A chat subscription (Claude Pro/Max, ChatGPT Plus, Gemini"
    echo "  Advanced) is NOT the same thing and will not work here."
    echo ""
    menu "Anthropic|Claude    console.anthropic.com" "Google|Gemini    aistudio.google.com" \
        "OpenAI|GPT       platform.openai.com" "OpenRouter|many      openrouter.ai"
    case "$CHOICE" in
        Anthropic)  PROVIDER_LABEL="Anthropic";  PROVIDER_ENVVAR="ANTHROPIC_API_KEY";  PROVIDER_ID="anthropic";  PROVIDER_MODEL="claude-haiku-5-5" ;;
        Google)     PROVIDER_LABEL="Gemini";     PROVIDER_ENVVAR="GEMINI_API_KEY";     PROVIDER_ID="gemini";     PROVIDER_MODEL="gemini-3.6-flash" ;;
        OpenAI)     PROVIDER_LABEL="OpenAI";     PROVIDER_ENVVAR="OPENAI_API_KEY";     PROVIDER_ID="";           PROVIDER_MODEL="" ;;
        OpenRouter) PROVIDER_LABEL="OpenRouter"; PROVIDER_ENVVAR="OPENROUTER_API_KEY"; PROVIDER_ID="openrouter"; PROVIDER_MODEL="" ;;
    esac

    echo ""
    read -rsp "  Paste your ${PROVIDER_LABEL} API key (typing is hidden): " PROVIDER_KEY </dev/tty
    echo ""
    PROVIDER_KEY="${PROVIDER_KEY//[[:space:]]/}"
    [[ -n "$PROVIDER_KEY" ]] || fail "No API key entered."

    if [[ "$PROVIDER_ENVVAR" == "ANTHROPIC_API_KEY" ]]; then
        info "Checking the key with Anthropic..."
        local code
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
            https://api.anthropic.com/v1/models \
            -H "x-api-key: ${PROVIDER_KEY}" \
            -H "anthropic-version: 2023-06-01" 2>/dev/null || echo 000)
        case "$code" in
            200)     ok "API key accepted." ;;
            401|403) fail "Anthropic rejected that key (HTTP $code). Copy it again and re-run." ;;
            000)     warn "Could not reach Anthropic to check. Continuing." ;;
            *)       warn "Unexpected reply while checking key (HTTP $code). Continuing." ;;
        esac
    else
        info "Key saved. It gets tested at the end of the install."
    fi
}

setup_telegram() {
    banner "Step 2 of 4 - Connect Telegram"
    echo ""
    echo "  This is how you will talk to your assistant, from any device."
    echo ""
    echo "  On your phone:"
    echo "    1. Open Telegram, search for:  @BotFather"
    echo "    2. Send:  /newbot"
    echo "    3. Give it any display name, then a username ending in 'bot'"
    echo "    4. BotFather replies with a token that looks like this:"
    echo "         123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    echo ""
    local c
    read -p "  Set up Telegram now? [Y/n]: " c </dev/tty
    if [[ "$c" =~ ^[Nn]$ ]]; then
        warn "Skipping. You can add it later: run this again and choose Telegram."
        return
    fi

    while :; do
        echo ""
        read -rp "  Paste the bot token: " TG_TOKEN </dev/tty
        TG_TOKEN="${TG_TOKEN//[[:space:]]/}"
        if [[ -z "$TG_TOKEN" ]]; then warn "Nothing entered."; continue; fi

        local resp
        resp=$(curl -fsS --max-time 20 "https://api.telegram.org/bot${TG_TOKEN}/getMe" 2>/dev/null || echo '')
        if [[ -z "$resp" ]] || [[ "$(echo "$resp" | jq -r '.ok // false' 2>/dev/null)" != "true" ]]; then
            warn "Telegram did not accept that token."
            read -p "  Try again? [Y/n]: " c </dev/tty
            if [[ "$c" =~ ^[Nn]$ ]]; then TG_TOKEN=""; return; fi
            continue
        fi
        TG_BOTNAME=$(echo "$resp" | jq -r '.result.username')
        ok "Connected to your bot: @${TG_BOTNAME}"
        break
    done

    # Capture the owner's numeric ID automatically. Done before the gateway
    # starts so nothing else is competing for getUpdates.
    echo ""
    echo -e "${CYAN}  Now open this link on your phone and press START:"
    echo "      https://t.me/${TG_BOTNAME}"
    echo -e "  Then send it any message, such as: hi${RESET}"
    echo ""
    info "Waiting for your message (up to 3 minutes)..."

    local waited=0 updates who
    while (( waited < 180 )); do
        updates=$(curl -fsS --max-time 15 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates" 2>/dev/null || echo '')
        TG_USERID=$(echo "$updates" | jq -r '[.result[]?.message.from.id] | last // empty' 2>/dev/null || echo '')
        if [[ -n "$TG_USERID" && "$TG_USERID" != "null" ]]; then
            who=$(echo "$updates" | jq -r '[.result[]?.message.from.first_name] | last // "you"' 2>/dev/null)
            ok "Paired with ${who} (ID ${TG_USERID}). Only this account can use the bot."
            break
        fi
        sleep 5; waited=$((waited + 5))
        if (( waited % 30 == 0 )); then info "  still waiting... (${waited}s)"; fi
    done

    if [[ -z "$TG_USERID" || "$TG_USERID" == "null" ]]; then
        warn "No message arrived. Install continues, but the bot is locked to nobody."
        warn "Run this again and choose Telegram to finish pairing."
        TG_USERID=""
    fi
}

setup_dashboard() {
    banner "Step 3 of 4 - Web dashboard (optional)"
    echo ""
    echo "  The dashboard is a web page on your home network where you can"
    echo "  see logs, skills, memory and settings in a browser. Telegram"
    echo "  works fine without it. You can turn it on later (choose Dashboard login)."
    echo ""
    local c
    read -p "  Enable the web dashboard? [Y/n]: " c </dev/tty
    if [[ "$c" =~ ^[Nn]$ ]]; then DASH_ENABLE=""; return; fi
    DASH_ENABLE="1"
    read -p "  Dashboard username [admin]: " DASH_USER </dev/tty
    DASH_USER="${DASH_USER:-admin}"
    while :; do
        read -rsp "  Dashboard password (8+ characters, typing is hidden): " DASH_PASS </dev/tty; echo ""
        (( ${#DASH_PASS} >= 8 )) && break
        warn "Too short."
    done
    ok "Dashboard will be enabled for ${DASH_USER}."
}

confirm_plan() {
    banner "Step 4 of 4 - Review"
    echo ""
    echo "  Container   : LXC named '$HOSTNAME' on $STORAGE"
    echo "  Resources   : ${CORES} cores, $((MEMORY/1024))GB RAM, ${DISK}GB disk"
    echo "  AI provider : ${PROVIDER_LABEL}${PROVIDER_MODEL:+ (${PROVIDER_MODEL})}"
    if [[ -n "$TG_TOKEN" ]]; then
        echo "  Telegram    : @${TG_BOTNAME}${TG_USERID:+  locked to ID ${TG_USERID}}"
    else
        echo "  Telegram    : not configured"
    fi
    if [[ -n "$DASH_ENABLE" ]]; then
        echo "  Dashboard   : on (home network only, user ${DASH_USER})"
    else
        echo "  Dashboard   : off"
    fi
    echo "  Timezone    : ${TIMEZONE}"
    echo ""
    echo "  Nothing is opened to the internet. The assistant only makes"
    echo "  outbound connections, so no ports or tunnels are needed."
    echo ""
    echo "  This takes 5-15 minutes, mostly downloading."
    echo ""
    local c
    read -p "  Proceed? [Y/n]: " c </dev/tty
    [[ "$c" =~ ^[Nn]$ ]] && fail "Cancelled."
}

# --- Container helpers -------------------------------------------------------
find_ctid() {
    local id
    for id in $(pct list | awk 'NR>1 {print $1}'); do
        if pct config "$id" 2>/dev/null | grep -q "hostname: ${HOSTNAME}"; then
            echo "$id"; return
        fi
    done
}

EXISTING_CTID="$(find_ctid || true)"

ct_ip() { pct exec "$1" -- ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true; }

# Keep the DHCP address for good: a moving IP breaks the sandbox firewall rules and links.
pin_ct_ip() {
    local ctid="$1" ip cidr gw net0
    net0=$(pct config "$ctid" | sed -n 's/^net0: //p')
    [[ "$net0" == *"ip=dhcp"* ]] || return 0
    ip="$(ct_ip "$ctid")"
    cidr=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4; exit}')
    gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
    [[ -n "$ip" && -n "$cidr" && -n "$gw" ]] || { warn "Could not fix the container IP; it stays on DHCP."; return 0; }
    pct set "$ctid" --net0 "${net0/ip=dhcp/ip=${ip}/${cidr#*/},gw=${gw}}" >/dev/null 2>&1 || true   # live apply can clash with the lease
    pct config "$ctid" | grep -q "^net0:.*ip=${ip}/" || { warn "Could not fix the container IP; it stays on DHCP."; return 0; }
    pct reboot "$ctid" >/dev/null
    local tries=0
    until pct exec "$ctid" -- getent hosts deb.debian.org >/dev/null 2>&1; do
        sleep 3; tries=$((tries + 1))
        (( tries > 20 )) && fail "Container lost its network after fixing the IP. Check CT $ctid."
    done
    ok "Container IP fixed at ${ip}. Reserve it in your router so no other device gets it."
}

sandbox_vmid() { qm list 2>/dev/null | awk 'NR>1 && $2 == "hermes-sb" {print $1; exit}'; }
run_sandbox() {
    local src
    src=$(wget -qLO- "${SANDBOX_URL}?$(date +%s)") && [[ -n "$src" ]] || { warn "Could not download setup-hermessb.sh."; return 1; }
    bash -c "$src" setup-hermessb "$@"
}

# Files in the data dir belong to the Hermes user, not root. docker exec runs as
# root by default, so commands that write there (config, tokens) must run as
# the data dir's owner or Hermes can no longer update them.
hermes_uid() {
    local uid
    uid=$(pct exec "$1" -- stat -c %u "${DATA_DIR}/data" 2>/dev/null || true)
    [[ "$uid" =~ ^[1-9][0-9]*$ ]] || uid=10000
    echo "$uid"
}
hx() { local id="$1"; shift; pct exec "$id" -- docker exec -u "$(hermes_uid "$id")" hermes hermes "$@"; }

pick_template() {
    pveam update >/dev/null 2>&1 || warn "Could not refresh template list; using cached."
    local t
    t=$(pveam available --section system 2>/dev/null | awk '/debian-12-standard/ {print $2}' | sort -V | tail -1)
    [[ -n "$t" ]] || fail "No Debian 12 template found."
    if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$t"; then
        info "Downloading container template (one time, ~120MB)..."
        pveam download "$TEMPLATE_STORAGE" "$t" >/dev/null || fail "Template download failed."
    fi
    echo "$t"
}

write_env() {
    local ctid="$1"
    pct exec "$ctid" -- bash -s <<EOSH || fail "Could not save credentials."
umask 077
mkdir -p ${DATA_DIR}/data
touch ${DATA_DIR}/data/.env
sed -i '/^${PROVIDER_ENVVAR}=/d' ${DATA_DIR}/data/.env 2>/dev/null || true
[ -n '${PROVIDER_KEY}' ] && echo '${PROVIDER_ENVVAR}=${PROVIDER_KEY}' >> ${DATA_DIR}/data/.env
if [ -n '${TG_TOKEN}' ]; then
  sed -i '/^TELEGRAM_/d' ${DATA_DIR}/data/.env 2>/dev/null || true
  echo 'TELEGRAM_BOT_TOKEN=${TG_TOKEN}' >> ${DATA_DIR}/data/.env
  if [ -n '${TG_USERID}' ]; then
    echo 'TELEGRAM_ALLOWED_USERS=${TG_USERID}' >> ${DATA_DIR}/data/.env
    echo 'TELEGRAM_HOME_CHANNEL=${TG_USERID}' >> ${DATA_DIR}/data/.env
  fi
fi
chmod 600 ${DATA_DIR}/data/.env
EOSH
    ok "Credentials saved."
}

write_dashboard_env() {
    # Dashboard settings live in their own file so they survive updates and
    # can be changed later without editing docker-compose.yml.
    local ctid="$1" secret
    secret="$(openssl rand -hex 32)"
    if [[ -n "$DASH_ENABLE" ]]; then
        pct exec "$ctid" -- bash -c "umask 077; cat > ${DATA_DIR}/dashboard.env <<EOF
HERMES_DASHBOARD=1
HERMES_DASHBOARD_BASIC_AUTH_USERNAME=${DASH_USER}
HERMES_DASHBOARD_BASIC_AUTH_PASSWORD=${DASH_PASS}
HERMES_DASHBOARD_BASIC_AUTH_SECRET=${secret}
EOF
sed -i 's/127\.0\.0\.1:${DASH_PORT}:/0.0.0.0:${DASH_PORT}:/' ${DATA_DIR}/docker-compose.yml"
    else
        pct exec "$ctid" -- bash -c "umask 077; : > ${DATA_DIR}/dashboard.env
sed -i 's/0\.0\.0\.0:${DASH_PORT}:/127.0.0.1:${DASH_PORT}:/' ${DATA_DIR}/docker-compose.yml"
    fi
    ok "Dashboard settings saved."
}

# Hermes reads the active model from model.default / model.provider.
set_model() {
    local ctid="$1"
    if [[ -n "$PROVIDER_ID" ]]; then
        hx "$ctid" config set model.provider "$PROVIDER_ID" >/dev/null 2>&1 \
            || warn "Could not set model.provider to ${PROVIDER_ID}."
    fi
    if [[ -n "$PROVIDER_MODEL" ]]; then
        hx "$ctid" config set model.default "$PROVIDER_MODEL" >/dev/null 2>&1 \
            || warn "Could not set model.default to ${PROVIDER_MODEL}."
    else
        info "Pick a ${PROVIDER_LABEL} model: pct exec ${ctid} -- docker exec -it -u $(hermes_uid "$ctid") hermes hermes setup model"
    fi
}

enable_telegram_platform() {
    # The setup wizard stores the token but does not add a platforms: block,
    # so the gateway starts with "no messaging platforms enabled". Set it here.
    local ctid="$1"
    [[ -z "$TG_TOKEN" ]] && return 0
    if ! hx "$ctid" config set platforms.telegram.enabled true >/dev/null 2>&1; then
        pct exec "$ctid" -- bash -c "
            grep -q '^platforms:' ${DATA_DIR}/data/config.yaml 2>/dev/null \
              || printf '\nplatforms:\n  telegram:\n    enabled: true\n' >> ${DATA_DIR}/data/config.yaml"
    fi
    ok "Telegram enabled."
}

smoke_test() {
    local ctid="$1" out=""
    info "Testing the AI connection (makes one real API call)..."
    out=$(hx "$ctid" chat -q "Reply with exactly: hermes-ok" 2>&1 || true)
    if grep -q "hermes-ok" <<<"$out"; then
        ok "AI provider is working."
    else
        warn "The test reply did not come back as expected:"
        echo "$out" | tail -12 | sed 's/^/    /'
        warn "Fix the provider (run this again and choose AI provider), or run:"
        warn "  pct exec ${ctid} -- docker exec -it -u $(hermes_uid "$ctid") hermes hermes setup model"
        return 1
    fi

    if [[ -n "$TG_TOKEN" && -n "$TG_USERID" ]]; then
        if hx "$ctid" send --to telegram \
             "Hermes is online and ready." >/dev/null 2>&1; then
            ok "Test message sent to your Telegram."
        else
            warn "Telegram test message failed. Run this again and choose Logs."
        fi
    fi
}

# --- Actions -----------------------------------------------------------------
action_install() {
    if [[ -n "$EXISTING_CTID" ]]; then
        warn "Hermes is already installed at CTID $EXISTING_CTID."
        echo "  Reinstalling DELETES its memory, skills, sessions and scheduled jobs."
        echo "  To keep them, quit now and choose Backup to file first."
        echo ""
        local c
        read -p "  Type 'reinstall' to continue: " c </dev/tty
        [[ "$c" == "reinstall" ]] || { info "Cancelled."; exit 0; }
        action_uninstall_silent
        EXISTING_CTID=""
    fi

    preflight
    choose_provider
    setup_telegram
    setup_dashboard
    confirm_plan

    local ctid=$CTID_DEFAULT
    while pct status "$ctid" &>/dev/null; do ctid=$((ctid + 1)); done
    info "Using CTID $ctid"

    local template pw
    template="$(pick_template)"
    pw="$(openssl rand -base64 16)"

    info "Creating the container..."
    pct create "$ctid" "${TEMPLATE_STORAGE}:vztmpl/${template}" \
        --timezone host \
        --hostname "$HOSTNAME" \
        --cores "$CORES" --memory "$MEMORY" --swap "$SWAP" \
        --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
        --rootfs "${STORAGE}:${DISK}" \
        --unprivileged 1 --features nesting=1,keyctl=1 --onboot 1 \
        --password "$pw" >/dev/null || fail "Container creation failed. See $LOG_FILE"

    echo "$pw" > "/root/.hermes-lxc-${ctid}.pw"; chmod 600 "/root/.hermes-lxc-${ctid}.pw"

    pct start "$ctid" || fail "Container would not start."

    info "Waiting for network..."
    local tries=0
    until pct exec "$ctid" -- getent hosts deb.debian.org >/dev/null 2>&1; do
        sleep 3; tries=$((tries + 1))
        (( tries > 20 )) && fail "Container has no internet. Check bridge '$BRIDGE' and your DHCP server."
    done
    pin_ct_ip "$ctid"

    info "Installing Docker (2-3 minutes)..."
    pct exec "$ctid" -- bash -c "
        export LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive
        echo 'LC_ALL=C' > /etc/default/locale
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1
    " || fail "Docker installation failed. See $LOG_FILE"
    ok "Docker installed."

    info "Downloading Hermes Agent (large image, 3-8 minutes)..."
    pct exec "$ctid" -- bash -c "
        set -e
        mkdir -p ${DATA_DIR}/data
        cat > ${DATA_DIR}/docker-compose.yml <<'YAML'
services:
  hermes:
    image: ${IMAGE}
    container_name: hermes
    command: gateway run
    restart: unless-stopped
    volumes:
      - ${DATA_DIR}/data:/opt/data
    ports:
      - \"${DASH_BIND}:${DASH_PORT}:${DASH_PORT}\"
      - \"${DASH_BIND}:${GW_PORT}:${GW_PORT}\"
    environment:
      - TZ=${TIMEZONE}
    env_file:
      - ${DATA_DIR}/dashboard.env
YAML
        : > ${DATA_DIR}/dashboard.env
        cd ${DATA_DIR} && docker compose pull -q && docker compose up -d
    " || fail "Hermes deployment failed. See $LOG_FILE"

    info "Waiting for first-run setup..."
    sleep 25
    pct exec "$ctid" -- docker ps --filter name=hermes --filter status=running -q | grep -q . \
        || fail "Hermes did not start. Run this again and choose Logs."
    ok "Hermes is running."

    write_env "$ctid"
    write_dashboard_env "$ctid"
    enable_telegram_platform "$ctid"
    set_model "$ctid"

    info "Restarting to apply settings..."
    pct exec "$ctid" -- bash -c "cd ${DATA_DIR} && docker compose up -d" >/dev/null
    sleep 15

    smoke_test "$ctid" || true

    local ip; ip="$(ct_ip "$ctid")"
    echo ""
    hr
    ok "Hermes Agent is ready."
    hr
    echo ""
    if [[ -n "$TG_USERID" ]]; then
        echo "  Open Telegram and message your bot:"
        echo "      https://t.me/${TG_BOTNAME}"
        echo ""
        echo "  Try asking:  what can you do?"
    else
        echo "  Telegram is not paired. Run this again and choose Telegram."
    fi
    echo ""
    echo "  Container : CTID ${ctid} at ${ip:-unknown}"
    echo "  Password  : /root/.hermes-lxc-${ctid}.pw"
    if [[ -n "$DASH_ENABLE" ]]; then
        echo "  Dashboard : http://${ip:-<container-ip>}:${DASH_PORT}  (user ${DASH_USER})"
        echo "              Home network only. Do NOT expose this through Cloudflare."
    fi
    echo "  Log file  : ${LOG_FILE}"
    echo ""
    echo "  Re-run this script anytime to check status, back up or update."
    echo ""
    if [[ -n "$(sandbox_vmid)" ]]; then
        # A reinstalled Hermes has a new key and maybe a new IP: reconnect the existing sandbox.
        info "Reconnecting Hermes to its sandbox..."
        run_sandbox install || warn "Sandbox reconnect stopped. Run this again and choose Sandbox, then Install."
    else
        info "Recommended: give Hermes its own sandbox computer for its terminal and browser,"
        echo "       cut off from your home network. Takes 5-10 minutes."
        local c
        read -rp "  Set up the sandbox now? [Y/n]: " c </dev/tty || c="n"
        if [[ "$c" =~ ^[Nn] ]]; then
            info "Later: run this again and choose Sandbox."
        else
            run_sandbox install || warn "Sandbox setup stopped. Hermes works without it; run this again and choose Sandbox."
        fi
    fi
}

action_add_telegram() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet. Choose Install."
    ensure_host_deps
    setup_telegram
    [[ -z "$TG_TOKEN" ]] && { info "Nothing changed."; return; }
    PROVIDER_ENVVAR="_UNUSED_"; PROVIDER_KEY=""
    write_env "$EXISTING_CTID"
    enable_telegram_platform "$EXISTING_CTID"
    pct exec "$EXISTING_CTID" -- docker restart hermes >/dev/null; sleep 15
    if hx "$EXISTING_CTID" send --to telegram \
         "Hermes is online and ready." >/dev/null 2>&1; then
        ok "Done. Check Telegram for a test message."
    else
        warn "Saved, but the test message failed. Run this again and choose Logs."
    fi
}

action_change_provider() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    ensure_host_deps
    choose_provider
    write_env "$EXISTING_CTID"
    set_model "$EXISTING_CTID"
    pct exec "$EXISTING_CTID" -- docker restart hermes >/dev/null; sleep 15
    smoke_test "$EXISTING_CTID" || true
}

# True when the container can resolve and reach Docker Hub.
container_online() {
    pct exec "$1" -- getent hosts registry-1.docker.io >/dev/null 2>&1
}

report_offline_container() {
    local ctid="$1" gw
    gw="$(pct exec "$ctid" -- ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
    warn "CTID $ctid cannot reach Docker Hub. Hermes is offline too until this is fixed."
    echo "  Gateway seen by the container: ${gw:-none}"
    echo "  Check from this host:"
    echo "    pct exec $ctid -- ip -4 addr show eth0"
    echo "    pct exec $ctid -- ip route"
    echo "    pct exec $ctid -- cat /etc/resolv.conf"
}

# Offers a container reboot, which renews the DHCP lease, then waits for
# the network to come back. Returns 1 if the user declines or it stays down.
recover_container_network() {
    local ctid="$1" c
    read -p "  Reboot CTID $ctid now to renew its network lease? [Y/n]: " c </dev/tty
    [[ "${c:-Y}" =~ ^[Yy]$ ]] || return 1
    info "Rebooting CTID $ctid..."
    pct reboot "$ctid" >/dev/null 2>&1 || { warn "pct reboot failed."; return 1; }
    for _ in $(seq 1 12); do
        sleep 5
        container_online "$ctid" && { ok "Network is back."; return 0; }
    done
    warn "Still no network after the reboot. Check bridge ${BRIDGE} and your DHCP server."
    return 1
}

action_update() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    info "Checking that the container can reach Docker Hub..."
    if ! container_online "$EXISTING_CTID"; then
        report_offline_container "$EXISTING_CTID"
        recover_container_network "$EXISTING_CTID" \
            || fail "Update stopped before any change was made."
    fi
    info "Taking a backup first..."
    action_backup || fail "Backup failed, so the update was stopped. Your data was not touched."
    info "Downloading the latest version..."
    # Docker installs do not support `hermes update`; pull a new image instead.
    if ! pct exec "$EXISTING_CTID" -- bash -c "
        cd ${DATA_DIR} && docker compose pull && docker compose up -d && docker image prune -f
    "; then
        # The pull may have dropped the network mid-way; leave the old version up.
        pct exec "$EXISTING_CTID" -- bash -c "cd ${DATA_DIR} && docker compose up -d" \
            >/dev/null 2>&1 || true
        fail "Update failed. Your data was not touched and Hermes is still running."
    fi
    sleep 15
    ok "Updated. Memory, skills and scheduled jobs were preserved."
}

action_logs() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    echo "  Live logs. Press Ctrl+C to stop."
    echo ""
    pct exec "$EXISTING_CTID" -- docker logs --tail 100 -f hermes
}

# Restarts Hermes after a backup, but only if the backup stopped it.
hermes_restart_after_backup() {
    [[ -z "${1:-}" ]] && return 0
    pct exec "$EXISTING_CTID" -- bash -c "cd ${DATA_DIR} && docker compose up -d" \
        >/dev/null 2>&1 || warn "Hermes did not restart. Run this again and choose Status."
}

action_backup() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."

    if [[ "$(pct status "$EXISTING_CTID" 2>/dev/null)" != "status: running" ]]; then
        warn "Container $EXISTING_CTID is not running. Start it with: pct start $EXISTING_CTID"
        return 1
    fi
    if ! pct exec "$EXISTING_CTID" -- test -d "${DATA_DIR}/data" 2>/dev/null; then
        warn "Nothing to back up: ${DATA_DIR}/data does not exist in CTID $EXISTING_CTID."
        return 1
    fi

    local stamp dest tmp err rc was_running=""
    stamp="$(date +%Y%m%d-%H%M%S)"
    dest="/root/hermes-backup-${stamp}.tar.gz"
    tmp="/tmp/hermes-backup-${stamp}.tar.gz"

    # Hermes keeps writing to its data dir, so stop it for a consistent copy.
    if pct exec "$EXISTING_CTID" -- docker inspect -f '{{.State.Running}}' hermes 2>/dev/null \
        | grep -q true; then
        was_running=1
        info "Pausing Hermes for a consistent copy..."
        pct exec "$EXISTING_CTID" -- docker stop hermes >/dev/null 2>&1 || true
    fi

    # pct exec streams stdout line by line, which corrupts a tar stream, so the
    # archive is written inside the container and copied out with pct pull.
    rc=0
    err="$(pct exec "$EXISTING_CTID" -- \
        tar --warning=no-file-changed -czf "$tmp" -C "${DATA_DIR}" data 2>&1)" || rc=$?
    # tar exits 1 for warnings such as a file changing as it was read; the
    # archive is still usable. Only 2 and above means it did not finish.
    if (( rc >= 2 )); then
        pct exec "$EXISTING_CTID" -- rm -f "$tmp" >/dev/null 2>&1 || true
        hermes_restart_after_backup "$was_running"
        [[ -n "$err" ]] && warn "$err"
        return 1
    fi
    [[ $rc -eq 1 && -n "$err" ]] && warn "$err"

    if ! err="$(pct pull "$EXISTING_CTID" "$tmp" "$dest" 2>&1)"; then
        pct exec "$EXISTING_CTID" -- rm -f "$tmp" >/dev/null 2>&1 || true
        rm -f "$dest"
        hermes_restart_after_backup "$was_running"
        [[ -n "$err" ]] && warn "$err"
        return 1
    fi
    pct exec "$EXISTING_CTID" -- rm -f "$tmp" >/dev/null 2>&1 || true
    hermes_restart_after_backup "$was_running"

    # The archive contains data/.env, so it holds API keys in plain text.
    chmod 600 "$dest"
    ok "Backup saved to: $dest ($(du -h "$dest" | awk '{print $1}'))"
}

# --- GitHub backup -----------------------------------------------------------
# A nightly job inside the container copies skills, scripts, scheduled jobs,
# settings and memories to a private GitHub repo, using a deploy key that can
# only reach that one repo. The job itself is apps/backup-hermes.sh.
GHB_TOOL_URL="https://github.com/therepos/proxmox/raw/main/apps/backup-hermes.sh"
GHB_KEY="/root/.ssh/backup_hermes"
GHB_CONF="/etc/backup-hermes.conf"
GHB_REPO_DEFAULT="therepos/backups"      # one repo for every app's backups (as setup-portainer)
GHB_DIR_DEFAULT="hermes"
GHB_CRON="/etc/cron.d/backup-hermes"
GHB_LOG="/var/log/backup-hermes.log"

ghb_conf_get() {  # ghb_conf_get <ctid> <VAR>
    pct exec "$1" -- sh -c ". $GHB_CONF 2>/dev/null; printf '%s' \"\$$2\"" 2>/dev/null || true
}

action_github_backup() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    [[ "$(pct status "$EXISTING_CTID" 2>/dev/null)" == "status: running" ]] \
        || fail "Container $EXISTING_CTID is not running. Start it with: pct start $EXISTING_CTID"
    local id="$EXISTING_CTID" c

    if pct exec "$id" -- test -f "$GHB_CRON" 2>/dev/null; then
        echo "  GitHub backup is on, nightly at 03:30."
        echo "    Repo   : $(ghb_conf_get "$id" HERMES_BACKUP_REPO)"
        echo "    Folder : $(ghb_conf_get "$id" HERMES_BACKUP_DIR)/"
        echo "  Last run:"
        pct exec "$id" -- tail -n 3 "$GHB_LOG" 2>/dev/null | sed 's/^/    /' \
            || echo "    (no runs yet)"
        menu "Back up now" "Restore" "Change repo or folder" "Turn off" "Back"
        echo ""
        case "$CHOICE" in
            "Back up now")           pct exec "$id" -- /usr/local/bin/backup-hermes.sh || fail "Backup failed."; return ;;
            Restore)                 ghb_restore "$id"; return ;;
            "Change repo or folder") ;;
            "Turn off")              ghb_off "$id"; return ;;
            Back)                    return ;;
        esac
    fi
    ghb_setup "$id"
}

# True when GitHub accepts the container's key for <repo>. Output in GHB_SSH_OUT.
# Read access is enough to pass; a key added without write access fails at push.
GHB_SSH_OUT=""
ghb_key_works() {  # ghb_key_works <ctid> <owner/repo>
    GHB_SSH_OUT=$(pct exec "$1" -- ssh -i "$GHB_KEY" -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new -o BatchMode=yes -T git@github.com 2>&1 || true)
    [[ "${GHB_SSH_OUT,,}" == *"hi ${2,,}!"* ]]
}

ghb_setup() {
    local id="$1" repo dir c code pub

    banner "Back up Hermes to GitHub"
    echo ""
    echo "  Every night Hermes copies its skills, scripts, scheduled jobs,"
    echo "  settings and memories to a GitHub repo. API keys and the Google"
    echo "  sign-in are never copied."
    echo ""
    echo "  Use a PRIVATE repo: memories and job prompts are personal."
    echo "  No repo yet? Create one at https://github.com/new (tick Private)."
    echo ""
    read -p "  Repo (owner/name) [${GHB_REPO_DEFAULT}]: " repo </dev/tty
    repo="${repo:-$GHB_REPO_DEFAULT}"
    repo="${repo#https://github.com/}"; repo="${repo%.git}"; repo="${repo%/}"
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "Enter it as owner/name, e.g. jane/backups."

    read -p "  Folder inside the repo [${GHB_DIR_DEFAULT}]: " dir </dev/tty
    dir="${dir:-$GHB_DIR_DEFAULT}"; dir="${dir#/}"; dir="${dir%/}"
    [[ "$dir" =~ ^[A-Za-z0-9_./-]+$ && "$dir" != *..* ]] || fail "Use letters, digits, - _ . and / only."
    if [[ "$dir" =~ ^(docs|static|public|src/pages)(/|$) ]]; then
        warn "Website builders (Docusaurus, MkDocs...) publish '${dir%%/*}/'."
        read -p "  Use '$dir' anyway? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
    fi

    ensure_host_deps
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://github.com/$repo" || echo 000)
    if [[ "$code" == "200" ]]; then
        warn "github.com/$repo is PUBLIC. Anyone could read your memories and prompts."
        read -p "  Continue anyway? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled. Make the repo private and try again."; return; }
    fi

    info "Preparing the container..."
    pct exec "$id" -- bash -c "apt-get install -y git rsync cron openssh-client >/dev/null 2>&1" \
        || fail "Could not install git/rsync/cron in the container."
    pct exec "$id" -- bash -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
        { [ -f $GHB_KEY ] || ssh-keygen -t ed25519 -N '' -C backup-hermes -f $GHB_KEY >/dev/null; }" \
        || fail "Could not create the backup key."
    # Reuse an existing key: only ask the user to add it if GitHub refuses it.
    if ghb_key_works "$id" "$repo"; then
        ok "GitHub already accepts this container's key for $repo."
    else
        pub=$(pct exec "$id" -- cat "$GHB_KEY.pub")
        echo ""
        banner "Add this key to GitHub (it can only reach $repo):"
        echo ""
        echo "  1. Open https://github.com/$repo/settings/keys/new"
        echo "  2. Title: backup-hermes"
        echo "  3. Key:"
        echo ""
        echo "     $pub"
        echo ""
        echo "  4. Tick 'Allow write access', then click 'Add key'."
        echo ""
        read -p "  Press Enter once the key is added..." _ </dev/tty
        echo ""
        if ! ghb_key_works "$id" "$repo"; then
            warn "GitHub did not accept the key for $repo:"
            echo "$GHB_SSH_OUT" | sed 's/^/    /'
            fail "Check the key was added to $repo with write access, then run this option again."
        fi
        ok "GitHub accepted the key."
    fi

    pct exec "$id" -- bash -c "umask 077; printf '%s\n' \
        'HERMES_BACKUP_REPO=git@github.com:${repo}.git' 'HERMES_BACKUP_DIR=${dir}' > $GHB_CONF" \
        || fail "Could not save backup settings."

    ghb_push_tool "$id"

    pct exec "$id" -- /usr/local/bin/backup-hermes.sh --install || fail "First backup failed."
    echo ""
    ok "GitHub backup is on: github.com/$repo/tree/HEAD/$dir"
}

ghb_push_tool() {  # refresh the backup job in the container from main
    local tmp; tmp=$(mktemp)
    curl -fsSL --max-time 30 "${GHB_TOOL_URL}?$(date +%s)" -o "$tmp" || { rm -f "$tmp"; fail "Could not download the backup job."; }
    pct push "$1" "$tmp" /usr/local/bin/backup-hermes.sh --perms 755 || { rm -f "$tmp"; fail "Could not copy the backup job."; }
    rm -f "$tmp"
}

ghb_restore() {
    local id="$1" c rc=0
    warn "This replaces Hermes' skills, scripts, scheduled jobs, settings and memories"
    warn "with the latest GitHub backup. API keys and the Google sign-in stay as they are."
    read -p "  Restore now? [y/N]: " c </dev/tty
    [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
    ghb_push_tool "$id"
    info "Stopping Hermes..."
    pct exec "$id" -- bash -c "cd ${DATA_DIR} && docker compose stop" >/dev/null 2>&1 || true
    pct exec "$id" -- env HERMES_DATA="${DATA_DIR}/data" /usr/local/bin/backup-hermes.sh --restore || rc=$?
    info "Starting Hermes..."
    pct exec "$id" -- bash -c "cd ${DATA_DIR} && docker compose up -d" >/dev/null || fail "Could not start Hermes."
    (( rc == 0 )) || fail "Restore failed. Hermes was started with its previous files."
    ok "Hermes restored and running."
}

ghb_off() {
    local id="$1" c repo
    repo=$(ghb_conf_get "$id" HERMES_BACKUP_REPO)
    read -p "  Turn off the nightly GitHub backup? [y/N]: " c </dev/tty
    [[ "$c" =~ ^[Yy]$ ]] || { info "Cancelled."; return; }
    pct exec "$id" -- rm -rf "$GHB_CRON" "$GHB_CONF" /root/backup-hermes-repo \
        "$GHB_KEY" "$GHB_KEY.pub" /usr/local/bin/backup-hermes.sh \
        /etc/cron.d/hermes-backup /etc/hermes-backup.conf /root/hermes-backup-repo \
        /root/.ssh/hermes_backup /root/.ssh/hermes_backup.pub /usr/local/bin/hermes-backup.sh
    ok "Nightly backup turned off. Files already on GitHub were left as they are."
    repo="${repo#git@github.com:}"; repo="${repo%.git}"
    if [[ -n "$repo" ]]; then
        echo "  Also delete the 'backup-hermes' (or older 'hermes-backup') key at https://github.com/$repo/settings/keys"
    fi
}

# --- Google (Gmail, Calendar) -------------------------------------------------
# Hermes' google-workspace skill signs in with OAuth. The browser lands on an
# unreachable http://localhost:1/?code=... page; the user pastes that address
# back and setup.py exchanges it for a token. Everything runs as the Hermes
# user so the token stays writable for the hourly refresh.
GSETUP="/opt/data/skills/productivity/google-workspace/scripts/setup.py"

gsetup() {  # gsetup <ctid> <setup.py args...>
    local id="$1"; shift
    pct exec "$id" -- docker exec -u "$(hermes_uid "$id")" hermes python "$GSETUP" "$@"
}

google_status() {  # one line: AUTHENTICATED... / NOT_AUTHENTICATED... / unavailable
    gsetup "$1" --check 2>&1 | head -n 1 || true
}

action_google() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    [[ "$(pct status "$EXISTING_CTID" 2>/dev/null)" == "status: running" ]] \
        || fail "Container $EXISTING_CTID is not running. Start it with: pct start $EXISTING_CTID"
    local id="$EXISTING_CTID" c st path url code uid
    uid="$(hermes_uid "$id")"
    pct exec "$id" -- docker exec hermes test -f "$GSETUP" \
        || fail "The google-workspace skill is missing. Update Hermes (choose Update) and try again."

    st="$(google_status "$id")"
    echo "  Google: $st"
    echo ""
    if [[ "$st" == AUTHENTICATED* ]]; then
        read -p "  Already connected. Reconnect anyway? [y/N]: " c </dev/tty
        [[ "$c" =~ ^[Yy]$ ]] || return 0
    fi

    if ! pct exec "$id" -- test -f "${DATA_DIR}/data/google_client_secret.json"; then
        echo "  First, Hermes needs a Google OAuth client (a JSON file):"
        echo "    1. https://console.cloud.google.com/apis/credentials"
        echo "    2. Create credentials -> OAuth client ID -> Desktop app"
        echo "    3. Download the JSON and copy it to this Proxmox host"
        echo "  Enable the Gmail and Google Calendar APIs in the same project."
        echo ""
        read -p "  Path to the JSON on this host: " path </dev/tty
        [[ -f "$path" ]] || fail "File not found: $path"
        pct push "$id" "$path" "${DATA_DIR}/data/.client_secret_upload.json" \
            --user "$uid" --group "$uid" --perms 600 || fail "Could not copy the file."
        gsetup "$id" --client-secret /opt/data/.client_secret_upload.json >/dev/null 2>&1 || true
        pct exec "$id" -- rm -f "${DATA_DIR}/data/.client_secret_upload.json"
        pct exec "$id" -- test -f "${DATA_DIR}/data/google_client_secret.json" \
            || fail "Hermes did not accept that file. Check it is the Desktop app JSON."
        ok "OAuth client saved."
        rm -i "$path" </dev/tty || true
    fi

    url="$(gsetup "$id" --auth-url 2>&1 | grep -oE 'https://accounts\.google\.com/[^ "]+' | head -n 1)"
    [[ -n "$url" ]] || fail "Could not get a sign-in link from Hermes."

    echo ""
    banner "1. Open this link and sign in with the Google account Hermes should use:"
    echo ""
    echo "$url"
    echo ""
    echo "  2. If Google warns the app is unverified: Advanced -> Go to ... (unsafe)."
    echo "  3. Tick every box and Continue."
    echo "  4. The browser ends on a 'site can't be reached' page at http://localhost:1/..."
    echo "     That is expected. Copy the WHOLE address from the address bar."
    echo ""
    read -r -p "  Paste the address here: " code </dev/tty
    code="${code//[[:space:]]/}"
    [[ "$code" == *code=* || ${#code} -gt 20 ]] || fail "That does not look like the address. Run this option again."

    gsetup "$id" --auth-code "$code" >/dev/null 2>&1 || true
    # Whatever ran setup before, the token must belong to Hermes and be private.
    pct exec "$id" -- sh -c "f=${DATA_DIR}/data/google_token.json; [ -f \$f ] && chown $uid:$uid \$f && chmod 600 \$f" || true

    st="$(google_status "$id")"
    if [[ "$st" == AUTHENTICATED* ]]; then
        ok "Google connected. Gmail and Calendar jobs will work from the next run."
    else
        warn "Google did not connect: $st"
        fail "The address may have expired (it lasts a few minutes). Run this option again."
    fi
}

action_uninstall_silent() {
    if [[ -n "$EXISTING_CTID" ]]; then
        pct stop "$EXISTING_CTID" 2>/dev/null || true
        pct destroy "$EXISTING_CTID" --purge 2>/dev/null || true
        rm -f "/root/.hermes-lxc-${EXISTING_CTID}.pw"
    fi
}

action_uninstall() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed."

    # Read the bot name out before the container is destroyed, so we can tell
    # the user exactly which bot to delete afterwards.
    local botname=""
    botname=$(pct exec "$EXISTING_CTID" -- bash -c \
        "grep -m1 '^TELEGRAM_BOT_TOKEN=' ${DATA_DIR}/data/.env 2>/dev/null | cut -d= -f2-" 2>/dev/null || true)
    if [[ -n "$botname" ]] && command -v curl >/dev/null && command -v jq >/dev/null; then
        botname=$(curl -fsS --max-time 10 "https://api.telegram.org/bot${botname}/getMe" 2>/dev/null \
            | jq -r '.result.username // empty' 2>/dev/null || true)
    else
        botname=""
    fi

    local ghb_repo
    ghb_repo=$(ghb_conf_get "$EXISTING_CTID" HERMES_BACKUP_REPO)
    ghb_repo="${ghb_repo#git@github.com:}"; ghb_repo="${ghb_repo%.git}"

    local sb; sb="$(sandbox_vmid)"
    if [[ -n "$sb" ]]; then
        warn "Hermes has a sandbox VM ($sb). It is useless without Hermes."
        local c=""
        read -rp "  Remove the sandbox first? [Y/n]: " c </dev/tty || c="n"
        [[ "$c" =~ ^[Nn] ]] || run_sandbox uninstall || warn "Sandbox not removed. Remove it later with setup-hermessb.sh, Uninstall."
    fi
    echo "  This permanently deletes container $EXISTING_CTID and everything inside:"
    echo "  memory, skills, sessions, scheduled jobs and saved API keys."
    echo ""
    local c
    read -p "  Type 'yes' to confirm: " c </dev/tty
    [[ "$c" == "yes" ]] || { info "Cancelled."; exit 0; }

    action_uninstall_silent
    ok "Container removed."

    # Backups contain the .env file, so they hold API keys in plain text.
    local backups
    backups=$(find /root -maxdepth 1 -name 'hermes-backup-*.tar.gz' 2>/dev/null | sort || true)
    if [[ -n "$backups" ]]; then
        echo ""
        warn "Backup files were found. These contain your API keys in plain text:"
        echo "$backups" | sed 's/^/    /'
        echo ""
        echo "  Keep them only if you plan to restore Hermes later."
        read -p "  Delete these backups? [y/N]: " c </dev/tty
        if [[ "$c" =~ ^[Yy]$ ]]; then
            echo "$backups" | xargs -r rm -f
            ok "Backups deleted."
        else
            warn "Backups kept. Store them somewhere safe or delete them yourself."
        fi
    fi

    local logs
    logs=$(find /var/log -maxdepth 1 -name 'hermes-install-*.log' 2>/dev/null || true)
    if [[ -n "$logs" ]]; then
        echo ""
        read -p "  Delete installer log files too? [y/N]: " c </dev/tty
        if [[ "$c" =~ ^[Yy]$ ]]; then
            # Keep today's log: this script is still writing to it.
            echo "$logs" | grep -v -F "$LOG_FILE" | xargs -r rm -f
            ok "Old logs deleted."
        fi
    fi

    EXISTING_CTID=""
    echo ""
    hr
    ok "Hermes fully removed."
    hr
    echo ""
    echo "  One last step, on your phone:"
    if [[ -n "$botname" ]]; then
        echo "    Open Telegram, message @BotFather, send /deletebot"
        echo "    and choose @${botname}."
    else
        echo "    Open Telegram, message @BotFather, send /deletebot"
        echo "    and choose the bot you created for Hermes."
    fi
    echo ""
    echo "  Until you do, that bot token stays valid."
    echo ""
    echo "  Also consider revoking the API key you used, at your"
    echo "  provider's website."
    if [[ -n "$ghb_repo" ]]; then
        echo ""
        echo "  GitHub backup: delete the 'backup-hermes' (or older 'hermes-backup') key at"
        echo "    https://github.com/${ghb_repo}/settings/keys"
    fi
    echo ""
}

action_dashboard() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet. Choose Install."
    setup_dashboard
    write_dashboard_env "$EXISTING_CTID"
    pct exec "$EXISTING_CTID" -- bash -c "cd ${DATA_DIR} && docker compose up -d" >/dev/null || fail "Restart failed."
    sleep 10
    if [[ -n "$DASH_ENABLE" ]]; then
        local ip; ip="$(ct_ip "$EXISTING_CTID")"
        ok "Dashboard is on: http://${ip:-<container-ip>}:${DASH_PORT}  (user ${DASH_USER})"
        echo "  Home network only. Do NOT expose this through Cloudflare."
    else
        ok "Dashboard is off."
    fi
}

action_status() {
    if [[ -z "$EXISTING_CTID" ]]; then
        info "Hermes is not installed."
        return
    fi
    local state ip
    state=$(pct status "$EXISTING_CTID" | awk '{print $2}')
    ip="$(ct_ip "$EXISTING_CTID")"

    echo ""
    echo "  Container : CTID $EXISTING_CTID  ${ip:-(no ip)}  [$state]"
    echo -n "  Image     : "
    pct exec "$EXISTING_CTID" -- docker ps --filter name=hermes \
        --format '{{.Image}}  ({{.Status}})' 2>/dev/null || echo "not running"

    echo ""
    echo "  Health check:"
    hx "$EXISTING_CTID" doctor 2>/dev/null \
        | sed 's/^/    /' || warn "    health check unavailable"

    echo ""
    echo "  Messaging:"
    hx "$EXISTING_CTID" gateway status 2>/dev/null \
        | sed 's/^/    /' || warn "    gateway not responding"

    echo ""
    if pct exec "$EXISTING_CTID" -- grep -q '^HERMES_DASHBOARD=1' "${DATA_DIR}/dashboard.env" 2>/dev/null; then
        echo "  Dashboard : http://${ip:-<container-ip>}:${DASH_PORT}"
    else
        echo "  Dashboard : off (choose Dashboard login to enable)"
    fi
    echo ""
    echo "  Google    : $(google_status "$EXISTING_CTID")"
    echo ""
    echo "  Scheduled jobs (last result):"
    hx "$EXISTING_CTID" cron list 2>/dev/null | awk '
        /Name:/     { sub(/^.*Name: */, ""); name = $0 }
        /Last run:/ { sub(/^.*Last run: */, ""); split($0, a, "  ")
                      printf "    %-34s %s\n", substr(name, 1, 34), substr(a[2], 1, 40) }' \
        || echo "    (unavailable)"
    echo ""
    if pct exec "$EXISTING_CTID" -- test -f "$GHB_CRON" 2>/dev/null; then
        echo "  GitHub    : nightly backup to $(ghb_conf_get "$EXISTING_CTID" HERMES_BACKUP_REPO)"
        pct exec "$EXISTING_CTID" -- tail -n 1 "$GHB_LOG" 2>/dev/null | sed 's/^/              last: /' || true
    else
        echo "  GitHub    : no backup (choose Backup to GitHub)"
    fi
    local sb; sb="$(sandbox_vmid)"
    if [[ -n "$sb" ]]; then echo "  Sandbox   : VM $sb (choose Sandbox for its self-test)"
    else echo "  Sandbox   : none (choose Sandbox to add one)"; fi
    echo -n "  Data size : "
    pct exec "$EXISTING_CTID" -- du -sh "${DATA_DIR}/data" 2>/dev/null | awk '{print $1}' || echo "unknown"
    echo ""
}

action_consent_pages() {
    # Google requires an external OAuth app in "production" to publish a home
    # page, privacy policy and terms of service on a domain you own. These are
    # static pages; they contain no user data. Served from the Hermes LXC and
    # exposed through an existing Cloudflare Tunnel route.
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet. Choose Install."

    banner "OAuth consent pages"
    echo ""
    echo "  Publishing your Google Cloud OAuth app stops refresh tokens from"
    echo "  expiring every 7 days. Google requires three public pages first."
    echo "  This serves them from Hermes on port ${PAGES_PORT}."
    echo ""
    menu "Install|or update the pages" "Remove|the pages" "Back"
    case "$CHOICE" in
        Back)    return 0 ;;
        Install) ;;
        Remove)
            pct exec "$EXISTING_CTID" -- bash -c "
                systemctl disable --now hermes-pages >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/hermes-pages.service
                rm -rf ${PAGES_DIR}
                systemctl daemon-reload >/dev/null 2>&1 || true" || true
            ok "Consent pages removed. Delete the Cloudflare route manually if unused."
            return ;;
    esac

    local host owner email law
    read -p "  Public hostname (e.g. hermes.example.com): " host </dev/tty
    host="${host//[[:space:]]/}"
    [[ -n "$host" ]] || fail "A hostname is required."
    read -p "  Owner name shown on the pages: " owner </dev/tty
    owner="${owner:-the owner}"
    read -p "  Contact email: " email </dev/tty
    email="${email//[[:space:]]/}"
    [[ -n "$email" ]] || fail "A contact email is required."
    read -p "  Governing law / country [Singapore]: " law </dev/tty
    law="${law:-Singapore}"

    local today; today="$(date +'%-d %B %Y')"

    info "Writing pages into the container..."
    pct exec "$EXISTING_CTID" -- bash -s <<EOSH || fail "Could not write the consent pages."
set -e
command -v python3 >/dev/null 2>&1 || {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq python3 >/dev/null 2>&1
}
mkdir -p ${PAGES_DIR}

cat > ${PAGES_DIR}/index.html <<'HTML'
<!doctype html><meta charset=utf-8><title>Personal Assistant</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>body{max-width:680px;margin:40px auto;padding:0 16px;font:16px/1.6 system-ui,sans-serif;color:#222}</style>
<h1>Personal Assistant</h1>
<p>A private, single-user automation tool operated by ${owner}. It connects only to its owner's own Google account &mdash; Gmail, Calendar and Drive &mdash; to organise mail, events and files.</p>
<p>There is no sign-up, no hosted service and no other user. The application runs on hardware controlled by its owner.</p>
<p>Use of information received from Google APIs adheres to the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements.</p>
<p>Contact: ${email}</p>
<p><a href="/privacy.html">Privacy Policy</a> &middot; <a href="/terms.html">Terms of Service</a></p>
HTML

cat > ${PAGES_DIR}/privacy.html <<'HTML'
<!doctype html><meta charset=utf-8><title>Privacy Policy</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>body{max-width:680px;margin:40px auto;padding:0 16px;font:16px/1.6 system-ui,sans-serif;color:#222}</style>
<h1>Privacy Policy</h1>
<p>Last updated: ${today}</p>
<p>Personal Assistant is operated by ${owner} (${email}) and has exactly one user: its owner. It does not accept registrations.</p>
<h2>Data accessed</h2>
<p>With the owner's explicit Google authorisation, the application may access, in the owner's own account: Gmail messages, labels and settings; Calendar events and availability; Drive files it creates or the owner opens with it; and the account email address.</p>
<h2>How it is used</h2>
<p>Solely to carry out tasks the owner requests, when he requests them. Never for advertising, profiling or resale.</p>
<h2>Storage</h2>
<p>Data is processed in memory and retained only as needed to complete a task. OAuth tokens are stored on the owner's own machine, readable only by his system account. No copy of Google user data is held on any third-party server operated by this application.</p>
<h2>Sharing</h2>
<p>Google user data is never sold, rented or shared. Where an external API is used to process a request, only the minimum content required is sent, and such providers may not use it to train models.</p>
<h2>Limited Use</h2>
<p>This application's use and transfer of information received from Google APIs to any other app adheres to the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>, including the Limited Use requirements.</p>
<h2>Security and revocation</h2>
<p>Access requires the owner's Google credentials and the application's own client secret. Authorisation can be revoked at any time at <a href="https://myaccount.google.com/permissions">myaccount.google.com/permissions</a>, which immediately ends all access.</p>
<h2>Deletion</h2>
<p>Revoking access, or deleting the local token file, removes any further ability to read data. Locally cached data is deleted by removing it from the owner's machine.</p>
<h2>Contact</h2>
<p>${email}</p>
<p><a href="/">Home</a> &middot; <a href="/terms.html">Terms of Service</a></p>
HTML

cat > ${PAGES_DIR}/terms.html <<'HTML'
<!doctype html><meta charset=utf-8><title>Terms of Service</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>body{max-width:680px;margin:40px auto;padding:0 16px;font:16px/1.6 system-ui,sans-serif;color:#222}</style>
<h1>Terms of Service</h1>
<p>Last updated: ${today}</p>
<p>Personal Assistant is a private application operated by ${owner} for his own use. It is not a commercial product and is not offered to the public.</p>
<h2>Permitted use</h2>
<p>Only the owner may authorise or operate the application. Any other access is unauthorised.</p>
<h2>Google services</h2>
<p>The application accesses Google services using the owner's own authorisation and complies with the Google API Services User Data Policy. Data handling is described in the <a href="/privacy.html">Privacy Policy</a>.</p>
<h2>No warranty</h2>
<p>Provided "as is", without warranty of any kind. It may be modified or discontinued at any time.</p>
<h2>Liability</h2>
<p>To the maximum extent permitted by law, the operator is not liable for any loss or damage arising from use of the application.</p>
<h2>Termination</h2>
<p>Authorisation may be revoked at any time at <a href="https://myaccount.google.com/permissions">myaccount.google.com/permissions</a>.</p>
<h2>Governing law</h2>
<p>These terms are governed by the laws of ${law}.</p>
<h2>Contact</h2>
<p>${email}</p>
<p><a href="/">Home</a> &middot; <a href="/privacy.html">Privacy Policy</a></p>
HTML

cat > /etc/systemd/system/hermes-pages.service <<'UNIT'
[Unit]
Description=Hermes OAuth consent pages
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 -m http.server ${PAGES_PORT} --bind 0.0.0.0 --directory ${PAGES_DIR}
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now hermes-pages >/dev/null 2>&1
EOSH

    sleep 2
    local ip; ip="$(ct_ip "$EXISTING_CTID")"
    if pct exec "$EXISTING_CTID" -- systemctl is-active --quiet hermes-pages; then
        ok "Pages are being served on port ${PAGES_PORT}."
    else
        warn "The page server did not start. Check: pct exec $EXISTING_CTID -- journalctl -u hermes-pages -n 30"
    fi

    echo ""
    banner "Next steps (done in a browser)"
    echo ""
    echo "  1. Cloudflare Tunnel route  ->  http://${ip:-<container-ip>}:${PAGES_PORT}"
    echo "     published as:            https://${host}"
    echo ""
    echo "  2. Verify the domain in Google Search Console (DNS TXT record)."
    echo ""
    echo "  3. Google Cloud -> Google Auth Platform -> Branding:"
    echo "       Home page       https://${host}/"
    echo "       Privacy policy  https://${host}/privacy.html"
    echo "       Terms           https://${host}/terms.html"
    echo "       Authorised domain: the root domain of ${host}"
    echo ""
    echo "  4. Audience -> Publish app, then reconnect Google (choose Google)."
    echo ""
    echo "  Note: the container uses DHCP, so if its IP changes you must"
    echo "  update the Cloudflare route."
    echo ""
}


# --- Local LLM ---------------------------------------------------------------
llm_val() { { grep -s "^$1=" "$LLM_ENV" || true; } | cut -d= -f2- | tr -d "'"; }

action_local_llm() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    ensure_host_deps
    if [[ ! -f "$LLM_ENV" ]]; then
        warn "No local LLM found (missing ${LLM_ENV})."
        echo "  Inside the GPU VM, run setup-llama.sh and choose Install first:"
        echo "    sudo bash -c \"\$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-llama.sh)\""
        return 1
    fi
    local key ip port model ctx base
    key="$(llm_val LLAMA_API_KEY)"; ip="$(llm_val LAN_IP)"; port="$(llm_val PORT)"
    model="$(llm_val MODEL_ALIAS)"; ctx="$(llm_val CTX)"
    if [[ -z "$ip" && -r /dev/tty ]]; then
        # Settings saved by an older setup-llama.sh have no address; ask once.
        read -rp "  GPU VM IP address (shown by 'setup-llama.sh > Status'): " ip </dev/tty
    fi
    [[ -n "$key" && -n "$ip" && -n "$port" && -n "$model" ]] \
        || fail "The local LLM settings file is incomplete. Re-run setup-llama.sh Install in the GPU VM."
    base="http://${ip}:${port}/v1"

    info "Checking the local model at ${base}..."
    if ! curl -fsS --max-time 5 -H "Authorization: Bearer ${key}" "${base}/models" >/dev/null 2>&1; then
        fail "The local model is not answering at ${base}. Is the GPU VM running? (In the VM: setup-llama.sh > Status)"
    fi
    ok "Local model is online (${model})."

    local ctid="$EXISTING_CTID"
    info "Pointing Hermes at it..."
    hx "$ctid" config set LLAMA_API_KEY "$key" >/dev/null 2>&1 || fail "Could not save the API key in Hermes."
    hx "$ctid" config set model.provider custom >/dev/null 2>&1
    hx "$ctid" config set model.default "$model" >/dev/null 2>&1
    hx "$ctid" config set model.base_url "$base" >/dev/null 2>&1
    hx "$ctid" config set model.key_env LLAMA_API_KEY >/dev/null 2>&1
    hx "$ctid" config set model.context_length "${ctx:-65536}" >/dev/null 2>&1
    ok "Hermes now uses the local model by default."

    # Claude stays one command away, and catches the turn if the VM is down.
    if pct exec "$ctid" -- grep -q '^ANTHROPIC_API_KEY=' "${DATA_DIR}/data/.env" 2>/dev/null; then
        hx "$ctid" config set model_aliases.sonnet.provider anthropic >/dev/null 2>&1
        hx "$ctid" config set model_aliases.sonnet.model "$LLM_SONNET" >/dev/null 2>&1
        hx "$ctid" config set model_aliases.opus.provider anthropic >/dev/null 2>&1
        hx "$ctid" config set model_aliases.opus.model "$LLM_OPUS" >/dev/null 2>&1
        pct exec "$ctid" -- bash -c "grep -q '^fallback_providers:' ${DATA_DIR}/data/config.yaml 2>/dev/null \
            || printf '\nfallback_providers:\n  - provider: anthropic\n    model: ${LLM_SONNET}\n' >> ${DATA_DIR}/data/config.yaml"
        ok "Claude shortcuts set: /model sonnet --once (judgement), /model opus --once (hard analysis)."
        ok "Safety net: if the VM is down, the turn goes to Claude Sonnet instead of failing."
    else
        warn "No Anthropic key in Hermes, so no Claude shortcuts or safety net. Add one later: choose AI provider."
    fi

    pct exec "$ctid" -- docker restart hermes >/dev/null; sleep 15
    smoke_test "$ctid" || return 1
    echo ""
    echo "  Done. Hermes works on your own GPU for free. In any chat, put"
    echo "    /model sonnet --once   or   /model opus --once"
    echo "  before a question that needs Claude. To go back to Claude for everything: choose AI provider."
    echo ""
}

# --- Menu --------------------------------------------------------------------
banner "Hermes Agent - Proxmox Installer"
echo ""
if [[ -n "$EXISTING_CTID" ]]; then
    ok "Installed (CTID $EXISTING_CTID)"
else
    info "Not installed"
    echo ""
    echo "  Hermes is a personal AI assistant that you message on"
    echo "  Telegram. It runs on your own hardware and can also work"
    echo "  on a schedule, for example a daily morning summary."
    echo ""
    echo "  Before starting, have ready:"
    echo "    - a paid AI provider API key"
    echo "    - your phone with Telegram installed"
fi
menu "Install" "Status" "Logs" "Update" "Backup to file" "Backup to GitHub|nightly" \
    "AI provider|or key" "Local LLM|use the GPU VM" "Telegram" "Google|Gmail, Calendar" \
    "Google consent pages" "Dashboard login" "Sandbox|own computer for terminal and browser" "Uninstall"
echo ""

case "$CHOICE" in
    Install)                action_install ;;
    Status)                 action_status ;;
    Logs)                   action_logs ;;
    Update)                 action_update ;;
    "Backup to file")       action_backup || fail "Backup failed." ;;
    "Backup to GitHub")     action_github_backup ;;
    "AI provider")          action_change_provider ;;
    "Local LLM")            action_local_llm ;;
    Telegram)               action_add_telegram ;;
    Google)                 action_google ;;
    "Google consent pages") action_consent_pages ;;
    "Dashboard login")      action_dashboard ;;
    Sandbox)                run_sandbox ;;
    Uninstall)              action_uninstall ;;
esac
