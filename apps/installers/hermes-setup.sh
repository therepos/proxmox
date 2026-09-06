#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/hermes-setup.sh?$(date +%s))"
# Purpose: Install / Update / Uninstall Hermes Agent LXC (Docker) on Proxmox
# =============================================================================

set -euo pipefail

LOG_DIR="/var/log"
LOG_FILE="$LOG_DIR/hermes-install-$(date +%F).log"
mkdir -p "$LOG_DIR"; : >"$LOG_FILE"; chmod 0644 "$LOG_FILE"
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
    hr
    echo "  Step 1 of 4 - Choose your AI provider"
    hr
    echo ""
    echo "  You need a paid API key from ONE of these providers."
    echo "  A chat subscription (Claude Pro/Max, ChatGPT Plus, Gemini"
    echo "  Advanced) is NOT the same thing and will not work here."
    echo ""
    echo "    1) Anthropic  - Claude    console.anthropic.com"
    echo "    2) Google     - Gemini    aistudio.google.com"
    echo "    3) OpenAI     - GPT       platform.openai.com"
    echo "    4) OpenRouter - many      openrouter.ai"
    echo ""
    local c
    read -p "  Select [1-4]: " c </dev/tty
    case "$c" in
        1) PROVIDER_LABEL="Anthropic";  PROVIDER_ENVVAR="ANTHROPIC_API_KEY";  PROVIDER_MODEL="claude-sonnet-5" ;;
        2) PROVIDER_LABEL="Gemini";     PROVIDER_ENVVAR="GEMINI_API_KEY";     PROVIDER_MODEL="gemini-3.6-flash" ;;
        3) PROVIDER_LABEL="OpenAI";     PROVIDER_ENVVAR="OPENAI_API_KEY";     PROVIDER_MODEL="" ;;
        4) PROVIDER_LABEL="OpenRouter"; PROVIDER_ENVVAR="OPENROUTER_API_KEY"; PROVIDER_MODEL="" ;;
        *) fail "Invalid choice." ;;
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
    hr
    echo "  Step 2 of 4 - Connect Telegram"
    hr
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
        warn "Skipping. You can add it later with menu option 2."
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
        warn "Re-run this script and choose option 2 to finish pairing."
        TG_USERID=""
    fi
}

setup_dashboard() {
    hr
    echo "  Step 3 of 4 - Web dashboard (optional)"
    hr
    echo ""
    echo "  The dashboard is a web page on your home network where you can"
    echo "  see logs, skills, memory and settings in a browser. Telegram"
    echo "  works fine without it. You can turn it on later (menu option 9)."
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
    hr
    echo "  Step 4 of 4 - Review"
    hr
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

hx() { local id="$1"; shift; pct exec "$id" -- docker exec hermes hermes "$@"; }

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
    out=$(pct exec "$ctid" -- docker exec hermes hermes chat -q "Reply with exactly: hermes-ok" 2>&1 || true)
    if grep -q "hermes-ok" <<<"$out"; then
        ok "AI provider is working."
    else
        warn "The test reply did not come back as expected:"
        echo "$out" | tail -12 | sed 's/^/    /'
        warn "Fix the provider with menu option 3, or run:"
        warn "  pct exec ${ctid} -- docker exec -it hermes hermes setup model"
        return 1
    fi

    if [[ -n "$TG_TOKEN" && -n "$TG_USERID" ]]; then
        if pct exec "$ctid" -- docker exec hermes hermes send --to telegram \
             "Hermes is online and ready." >/dev/null 2>&1; then
            ok "Test message sent to your Telegram."
        else
            warn "Telegram test message failed. Check menu option 5 (logs)."
        fi
    fi
}

# --- Actions -----------------------------------------------------------------
action_install() {
    if [[ -n "$EXISTING_CTID" ]]; then
        warn "Hermes is already installed at CTID $EXISTING_CTID."
        echo "  Reinstalling DELETES its memory, skills, sessions and scheduled jobs."
        echo "  To keep them, quit now and run menu option 6 (Backup) first."
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
        || fail "Hermes did not start. Run menu option 5 to view logs."
    ok "Hermes is running."

    write_env "$ctid"
    write_dashboard_env "$ctid"
    enable_telegram_platform "$ctid"
    if [[ -n "$PROVIDER_MODEL" ]]; then
        hx "$ctid" config set model.name "$PROVIDER_MODEL" >/dev/null 2>&1 || true
    fi

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
        echo "  Telegram is not paired. Re-run this script and choose option 2."
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
}

action_add_telegram() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet. Choose option 1."
    ensure_host_deps
    setup_telegram
    [[ -z "$TG_TOKEN" ]] && { info "Nothing changed."; return; }
    PROVIDER_ENVVAR="_UNUSED_"; PROVIDER_KEY=""
    write_env "$EXISTING_CTID"
    enable_telegram_platform "$EXISTING_CTID"
    pct exec "$EXISTING_CTID" -- docker restart hermes >/dev/null; sleep 15
    if pct exec "$EXISTING_CTID" -- docker exec hermes hermes send --to telegram \
         "Hermes is online and ready." >/dev/null 2>&1; then
        ok "Done. Check Telegram for a test message."
    else
        warn "Saved, but the test message failed. Check menu option 5 (logs)."
    fi
}

action_change_provider() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    ensure_host_deps
    choose_provider
    write_env "$EXISTING_CTID"
    if [[ -n "$PROVIDER_MODEL" ]]; then
        hx "$EXISTING_CTID" config set model.name "$PROVIDER_MODEL" >/dev/null 2>&1 || true
    fi
    pct exec "$EXISTING_CTID" -- docker restart hermes >/dev/null; sleep 15
    smoke_test "$EXISTING_CTID" || true
}

action_update() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    info "Taking a backup first..."
    action_backup
    info "Downloading the latest version..."
    # Docker installs do not support `hermes update`; pull a new image instead.
    pct exec "$EXISTING_CTID" -- bash -c "
        cd ${DATA_DIR} && docker compose pull && docker compose up -d && docker image prune -f
    " || fail "Update failed. Your data was not touched."
    sleep 15
    ok "Updated. Memory, skills and scheduled jobs were preserved."
}

action_logs() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    echo "  Live logs. Press Ctrl+C to stop."
    echo ""
    pct exec "$EXISTING_CTID" -- docker logs --tail 100 -f hermes
}

action_backup() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet."
    local dest="/root/hermes-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    pct exec "$EXISTING_CTID" -- tar czf - -C "${DATA_DIR}" data > "$dest" 2>/dev/null \
        || fail "Backup failed."
    ok "Backup saved to: $dest"
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
    echo ""
}

action_dashboard() {
    [[ -z "$EXISTING_CTID" ]] && fail "Hermes is not installed yet. Choose option 1."
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
    pct exec "$EXISTING_CTID" -- docker exec hermes hermes doctor 2>/dev/null \
        | sed 's/^/    /' || warn "    health check unavailable"

    echo ""
    echo "  Messaging:"
    pct exec "$EXISTING_CTID" -- docker exec hermes hermes gateway status 2>/dev/null \
        | sed 's/^/    /' || warn "    gateway not responding"

    echo ""
    if pct exec "$EXISTING_CTID" -- grep -q '^HERMES_DASHBOARD=1' "${DATA_DIR}/dashboard.env" 2>/dev/null; then
        echo "  Dashboard : http://${ip:-<container-ip>}:${DASH_PORT}"
    else
        echo "  Dashboard : off (menu option 9 to enable)"
    fi
    echo ""
    echo -n "  Data size : "
    pct exec "$EXISTING_CTID" -- du -sh "${DATA_DIR}/data" 2>/dev/null | awk '{print $1}' || echo "unknown"
    echo ""
}

# --- Menu --------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Hermes Agent - Proxmox Installer"
echo "================================================================"
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
echo ""
echo "  1) Install"
echo "  2) Connect or re-pair Telegram"
echo "  3) Change AI provider or key"
echo "  4) Show status"
echo "  5) View logs"
echo "  6) Backup"
echo "  7) Update to latest version"
echo "  8) Uninstall"
echo "  9) Enable, disable or reset dashboard login"
echo "  q) Quit"
echo ""
read -p "Select an option: " choice </dev/tty
echo ""

case "$choice" in
    1) action_install ;;
    2) action_add_telegram ;;
    3) action_change_provider ;;
    4) action_status ;;
    5) action_logs ;;
    6) action_backup ;;
    7) action_update ;;
    8) action_uninstall ;;
    9) action_dashboard ;;
    q|Q) info "Bye."; exit 0 ;;
    *) fail "Invalid option." ;;
esac
