#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-hermessb.sh?$(date +%s))"
# Purpose: Sandbox VM for Hermes Agent: its browser (optionally its terminal) runs there, cut off from the LAN
# =============================================================================
# Usage:
#   setup-hermessb            menu
#   setup-hermessb install    install, or repair an existing sandbox
#   setup-hermessb uninstall  delete the sandbox (asks first)
# =============================================================================

set -euo pipefail

SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-hermessb.sh"

# >>> shortcut
SHORTCUT_RC="${HOME:-/root}/.bashrc"
shortcut_name() { local n="${SCRIPT_URL##*/}"; printf '%s' "${n%.sh}"; }
shortcut_line() {
  # shellcheck disable=SC2016  # expanded when the shortcut runs
  printf '%s() { bash -c "$(wget -qLO- %s?$(date +%%s))" %s "$@"; }' "$(shortcut_name)" "$SCRIPT_URL" "$(shortcut_name)"
}
shortcut_on() { grep -qxF "$(shortcut_line)" "$SHORTCUT_RC" 2>/dev/null; }
shortcut_state() { if shortcut_on; then printf on; else printf off; fi; }
shortcut_toggle() {
  local was=0; shortcut_on && was=1
  [[ -f "$SHORTCUT_RC" ]] && sed -i "/^$(shortcut_name)() /d" "$SHORTCUT_RC"
  if (( was )); then ok "Shortcut removed."; return 0; fi
  printf '%s\n' "$(shortcut_line)" >> "$SHORTCUT_RC"
  ok "Shortcut added. In a new shell, type: $(shortcut_name)"
}
# <<< shortcut

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

[[ $EUID -eq 0 ]] || fail "Run as root."

LOG_FILE="/var/log/hermessb-$(date +%F).log"
: >>"$LOG_FILE"; chmod 0644 "$LOG_FILE"
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

# --- Config ------------------------------------------------------------------
VM_NAME="hermes-sb"
VMID_DEFAULT=220
VM_USER_DEFAULT="toor"
CORES_DEFAULT=2
MEMORY_GB_DEFAULT=4
DISK_GB_DEFAULT=32
BRIDGE="vmbr0"

HERMES_HOSTNAME="hermes"
HERMES_DATA="/opt/hermes/data"          # Hermes data dir in the LXC (/opt/data in its container)
HERMES_KEY="${HERMES_DATA}/.ssh/hermes_sb"
HERMES_KEY_IN="/opt/data/.ssh/hermes_sb"

CDP_PORT=9223
IMG_RELEASE="resolute"
IMG_URL="https://cloud-images.ubuntu.com/${IMG_RELEASE}/current/${IMG_RELEASE}-server-cloudimg-amd64.img"
IMG_FILE="/var/lib/vz/template/iso/hermessb-${IMG_RELEASE}.img"
SETUP_HERMES_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-hermes.sh"

# Filled by detect_*
HOST_IP=""; PREFIX=""; GW=""; DNS=""; NET_CIDR=""
CTID=""; HERMES_IP=""; HERMES_UID=""
VMID=""; SB_IP=""; VM_USER=""; CORES=""; MEMORY_GB=""; DISK_GB=""; STORAGE=""

# --- Helpers -----------------------------------------------------------------
has_tty() { { true </dev/tty; } 2>/dev/null; }
ask() { # ask "prompt" default -> answer on stdout; Enter or no tty keeps the default
    local a=""
    has_tty && { read -rp "  $1 [$2]: " a </dev/tty || a=""; }
    printf '%s' "${a:-$2}"
}
yes_no() { # yes_no "question" -> true on Enter/y; false on n or no tty
    local a=""
    has_tty || return 1
    read -rp "  $1 [Y/n]: " a </dev/tty || return 1
    [[ ! "$a" =~ ^[Nn] ]]
}
no_yes() { # no_yes "question" -> true only on y; for choices that break things
    local a=""
    has_tty || return 1
    read -rp "  $1 [y/N]: " a </dev/tty || return 1
    [[ "$a" =~ ^[Yy] ]]
}

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }
valid_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && ! [[ "$1" =~ (^|\.)(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2}) ]]; }
in_subnet() { # in_subnet ip -> true when ip is a usable host address in the LAN
    local n m i
    m=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
    n=$(( $(ip2int "$HOST_IP") & m )); i=$(ip2int "$1")
    (( (i & m) == n && i != n && i != (n | (~m & 0xFFFFFFFF)) ))
}
is_private() {
    local i; i=$(ip2int "$1")
    (( (i >> 24) == 10 || (i >> 20) == 0xAC1 || (i >> 16) == 0xC0A8 || (i >> 22) == 0x191 ))
}

# Free = not the host, gateway or Hermes, not set on any guest, and no reply to ping or ARP.
ip_free() {
    local ip="$1"
    [[ "$ip" != "$HOST_IP" && "$ip" != "$GW" && "$ip" != "$HERMES_IP" ]] || return 1
    grep -qsE "ip=${ip//./\\.}/" /etc/pve/nodes/*/qemu-server/*.conf /etc/pve/nodes/*/lxc/*.conf && return 1
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && return 1
    ip neigh show "$ip" 2>/dev/null | grep -q lladdr && return 1
    return 0
}

# Counts down from the top of the LAN, which most routers keep outside their DHCP range.
pick_ip() {
    local m n top i c
    m=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
    n=$(( $(ip2int "$HOST_IP") & m ))
    top=$(( (n | (~m & 0xFFFFFFFF)) - 5 ))
    for (( i = 0; i < 60; i++ )); do
        c=$(int2ip $(( top - i )))
        in_subnet "$c" && ip_free "$c" && { echo "$c"; return 0; }
    done
    return 1
}

vmid_used() { compgen -G "/etc/pve/nodes/*/qemu-server/$1.conf" >/dev/null || compgen -G "/etc/pve/nodes/*/lxc/$1.conf" >/dev/null; }

# --- Detection ---------------------------------------------------------------
detect_host() {
    command -v qm >/dev/null && command -v pct >/dev/null \
        || fail "Run this on the Proxmox host, not inside a VM or LXC."
    local cidr
    cidr=$(ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | awk '{print $4; exit}' || true)
    [[ -n "$cidr" ]] || fail "No IPv4 address on bridge $BRIDGE."
    HOST_IP="${cidr%/*}"; PREFIX="${cidr#*/}"
    (( PREFIX >= 8 && PREFIX <= 30 )) || fail "Unsupported network size /$PREFIX on $BRIDGE."
    GW=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}' || true)
    [[ -n "$GW" ]] || fail "No default gateway on this host."
    DNS=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
    valid_ip "${DNS:-x}" && [[ "$DNS" != 127.* ]] || DNS="$GW"
    local m; m=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
    NET_CIDR="$(int2ip $(( $(ip2int "$HOST_IP") & m )))/${PREFIX}"
}

find_ctid() {
    local id
    for id in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
        pct config "$id" 2>/dev/null | grep -qx "hostname: ${HERMES_HOSTNAME}" && { echo "$id"; return 0; }
    done
    return 1
}
find_vmid() { qm list 2>/dev/null | awk -v n="$VM_NAME" 'NR>1 && $2 == n {print $1; exit}' || true; }
ct_ip() { pct exec "$1" -- ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true; }
vm_ip() { qm config "$1" 2>/dev/null | sed -n 's/^ipconfig0:.*ip=\([0-9.]*\)\/.*/\1/p'; }
vm_user() { qm config "$1" 2>/dev/null | sed -n 's/^ciuser: //p'; }

hermes_uid() {
    local uid
    uid=$(pct exec "$CTID" -- stat -c %u "$HERMES_DATA" 2>/dev/null || true)
    [[ "$uid" =~ ^[1-9][0-9]*$ ]] || uid=10000
    echo "$uid"
}
hx() { pct exec "$CTID" -- docker exec -u "$HERMES_UID" -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes hermes "$@"; }
hermes_running() { pct exec "$CTID" -- docker ps --filter name=^hermes$ --filter status=running -q 2>/dev/null | grep -q .; }

# Hermes must exist; offer its installer when it does not.
detect_hermes() {
    CTID="$(find_ctid || true)"
    if [[ -z "$CTID" ]]; then
        warn "Hermes Agent is not installed. The sandbox works for Hermes, so install it first."
        if yes_no "Run the Hermes installer now?"; then
            local src
            src=$(wget -qLO- "${SETUP_HERMES_URL}?$(date +%s)") && [[ -n "$src" ]] || fail "Could not download setup-hermes.sh."
            bash -c "$src" setup-hermes
        fi
        exit 0
    fi
    [[ "$(pct status "$CTID" | awk '{print $2}')" == "running" ]] || pct start "$CTID" >/dev/null
    local t=0
    until hermes_running; do
        sleep 3; t=$((t + 3))
        (( t > 90 )) && fail "Hermes (CT $CTID) is not running. Check it with setup-hermes.sh, choose Status."
    done
    HERMES_IP="$(ct_ip "$CTID")"
    [[ -n "$HERMES_IP" ]] || fail "Hermes (CT $CTID) has no IP address."
    HERMES_UID="$(hermes_uid)"
}

# Like detect_hermes, but never stops: Uninstall must work even when Hermes is gone.
detect_hermes_soft() {
    CTID="$(find_ctid || true)"
    [[ -n "$CTID" ]] && hermes_running || { CTID=""; return 0; }
    HERMES_IP="$(ct_ip "$CTID")"; HERMES_UID="$(hermes_uid)"
}

hermes_env() { [[ -n "$CTID" ]] && pct exec "$CTID" -- sed -n "s/^$1=//p" "${HERMES_DATA}/.env" 2>/dev/null | head -1; }

# Fills settings from an existing sandbox; a hand-built one has no cloud-init, so fall back to Hermes' settings.
load_existing() {
    VMID="$1"
    SB_IP="$(vm_ip "$VMID")"; VM_USER="$(vm_user "$VMID")"
    [[ -n "$SB_IP" ]] || SB_IP="$(hermes_env TERMINAL_SSH_HOST || true)"
    [[ -n "$VM_USER" ]] || VM_USER="$(hermes_env TERMINAL_SSH_USER || true)"
    [[ -n "$SB_IP" && -n "$VM_USER" ]]
}

pick_storage() {
    if pvesm status --content images 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx local-lvm; then
        echo local-lvm
    else
        pvesm status --content images 2>/dev/null | awk 'NR>1 && $3 == "active" {print $1; exit}'
    fi
}

# --- Steps -------------------------------------------------------------------
# A DHCP address can move, which would break the firewall rule and Hermes' link to
# the sandbox, so the Hermes LXC keeps the address it has now.
pin_hermes_ip() {
    local net0 new
    net0=$(pct config "$CTID" | sed -n 's/^net0: //p')
    [[ "$net0" == *"ip=dhcp"* ]] || { ok "Hermes keeps its fixed IP ${HERMES_IP}."; return 0; }
    if [[ "$net0" != *"bridge=${BRIDGE}"* || "$net0" == *"tag="* ]] || ! in_subnet "$HERMES_IP"; then
        warn "Hermes is not on this host's LAN (${BRIDGE}, ${NET_CIDR}); its IP stays on DHCP."
        warn "Reserve ${HERMES_IP} in your router, or the sandbox loses Hermes when it changes."
        return 0
    fi
    new="${net0/ip=dhcp/ip=${HERMES_IP}/${PREFIX},gw=${GW}}"
    info "Fixing Hermes' IP at ${HERMES_IP} (Hermes restarts, about 30 seconds)..."
    pct set "$CTID" --net0 "$new" >/dev/null 2>&1 || true   # live apply can clash with the DHCP lease
    pct config "$CTID" | grep -q "^net0:.*ip=${HERMES_IP}/" || fail "Could not fix the IP of CT $CTID."
    pct reboot "$CTID" >/dev/null
    local t=0
    until hermes_running; do
        sleep 3; t=$((t + 3))
        (( t > 120 )) && fail "Hermes did not come back after the restart. Check CT $CTID."
    done
    [[ "$(ct_ip "$CTID")" == "$HERMES_IP" ]] || fail "Hermes came back on a different IP. Check CT $CTID."
    ok "Hermes IP fixed at ${HERMES_IP}."
}

ensure_hermes_key() {
    if ! pct exec "$CTID" -- test -f "$HERMES_KEY"; then
        pct exec "$CTID" -- sh -c 'command -v ssh-keygen >/dev/null || { apt-get update -qq && apt-get install -y -qq openssh-client; } >/dev/null 2>&1' \
            || fail "Could not install ssh-keygen in CT $CTID."
        pct exec "$CTID" -- sh -c "mkdir -p '${HERMES_DATA}/.ssh' && ssh-keygen -q -t ed25519 -N '' -C hermes-to-sb -f '$HERMES_KEY'" \
            || fail "Could not create the Hermes SSH key."
        ok "Hermes SSH key created."
    fi
    pct exec "$CTID" -- sh -c "chown -R ${HERMES_UID}:${HERMES_UID} '${HERMES_DATA}/.ssh' && chmod 700 '${HERMES_DATA}/.ssh' && chmod 600 '$HERMES_KEY'" \
        || fail "Could not set permissions on the Hermes SSH key."
}

host_pubkey() {
    local f
    for f in /root/.ssh/id_ed25519.pub /root/.ssh/id_rsa.pub; do [[ -f "$f" ]] && { echo "$f"; return; }; done
    ssh-keygen -q -t ed25519 -N '' -f /root/.ssh/id_ed25519
    echo /root/.ssh/id_ed25519.pub
}

fetch_image() {
    if [[ -s "$IMG_FILE" ]]; then ok "Ubuntu cloud image already downloaded."; return; fi
    info "Downloading the Ubuntu cloud image (about 600 MB)..."
    mkdir -p "$(dirname "$IMG_FILE")"
    curl -fL --retry 3 -sS -o "${IMG_FILE}.part" "$IMG_URL" || { rm -f "${IMG_FILE}.part"; fail "Download failed: $IMG_URL"; }
    mv "${IMG_FILE}.part" "$IMG_FILE"
    ok "Image downloaded."
}

write_keys() { # write_keys <file>: this host's key and Hermes' key
    cat "$(host_pubkey)" > "$1" && pct exec "$CTID" -- cat "${HERMES_KEY}.pub" >> "$1"
}

# A half-built VM would block both Install and Uninstall, so remove it on any failure.
create_vm() {
    local keys fmt=""
    keys=$(mktemp)
    undo() { rm -f "$keys"; qm destroy "$VMID" --purge >/dev/null 2>&1 || true; fail "$1 See $LOG_FILE"; }
    write_keys "$keys" || { rm -f "$keys"; fail "Could not read the SSH keys."; }
    [[ "$(pvesm status 2>/dev/null | awk -v s="$STORAGE" '$1 == s {print $2}' || true)" == dir ]] && fmt=",format=qcow2"
    info "Creating VM $VMID ($VM_NAME)..."
    qm create "$VMID" --name "$VM_NAME" --ostype l26 --cpu host --cores "$CORES" \
        --memory $(( MEMORY_GB * 1024 )) --balloon 0 --agent enabled=1 --onboot 1 \
        --scsihw virtio-scsi-single --net0 "virtio,bridge=${BRIDGE},firewall=1" \
        --serial0 socket --vga serial0 >/dev/null || { rm -f "$keys"; fail "qm create failed. See $LOG_FILE"; }
    qm set "$VMID" --scsi0 "${STORAGE}:0,import-from=${IMG_FILE},discard=on,iothread=1,ssd=1${fmt}" >/dev/null \
        || undo "Disk import failed."
    qm resize "$VMID" scsi0 "${DISK_GB}G" >/dev/null || undo "Disk resize failed."
    qm set "$VMID" --ide2 "${STORAGE}:cloudinit" --boot order=scsi0 \
        --ciuser "$VM_USER" --sshkeys "$keys" \
        --ipconfig0 "ip=${SB_IP}/${PREFIX},gw=${GW}" --nameserver "$DNS" >/dev/null \
        || undo "Cloud-init settings failed."
    rm -f "$keys"
    ok "VM $VMID created."
}

# A hand-built VM may lack firewall=1 on its NIC, which makes its rules a no-op.
ensure_vm_firewall_nic() {
    local net0; net0=$(qm config "$VMID" | sed -n 's/^net0: //p')
    [[ -n "$net0" ]] || fail "VM $VMID has no network card."
    [[ "$net0" == *"firewall=1"* ]] && return 0
    qm set "$VMID" --net0 "${net0/firewall=0/},firewall=1" >/dev/null || fail "Could not turn on the firewall for VM $VMID's network card."
    ok "Firewall turned on for VM $VMID's network card."
}

# Hermes' key reaches the VM only through cloud-init at creation; add it again after a Hermes reinstall.
authorize_hermes_key() {
    local pub keys
    pub=$(pct exec "$CTID" -- cat "${HERMES_KEY}.pub") || fail "Could not read Hermes' SSH key."
    if ! sb_ssh "grep -qxF '$pub' ~/.ssh/authorized_keys" 2>/dev/null; then
        sb_ssh "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '$pub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
            || fail "Could not add Hermes' key to the sandbox."
        ok "Hermes' current SSH key added to the sandbox."
    fi
    if qm config "$VMID" | grep -q '^ciuser:'; then
        keys=$(mktemp); write_keys "$keys" && qm set "$VMID" --sshkeys "$keys" >/dev/null; rm -f "$keys"
    fi
}

# Switching on a firewall that exists but is off would also activate the user's dormant rules.
firewall_precheck() {
    local cfw=/etc/pve/firewall/cluster.fw active pin
    [[ -f "$cfw" ]] || return 0
    grep -qx 'enable: 1' "$cfw" && return 0
    pin=$(sed -n 's/^policy_in: *//p' "$cfw" || true)
    active=$(grep -lx 'enable: 1' /etc/pve/firewall/*.fw /etc/pve/nodes/*/host.fw 2>/dev/null | tr '\n' ' ' || true)
    warn "The Proxmox firewall is set up on this host but switched off."
    echo "       The sandbox needs it on. That also activates your existing settings:"
    echo "       incoming policy: ${pin:-ACCEPT (will be added)}"
    echo "       files with rules switched on: ${active:-none}"
    [[ "${pin^^}" == DROP ]] && warn "Incoming DROP can cut off web UI access over Tailscale or VPN."
    yes_no "Switch the Proxmox firewall on?" || fail "Cancelled. Nothing changed."
}

# Inbound: SSH from the LAN (keys only) and the browser port from Hermes only.
# Outbound: internet over IPv4 only; no LAN, private, link-local, multicast or IPv6.
write_firewall() {
    local cfw=/etc/pve/firewall/cluster.fw dns_rules="" new old changed=0
    mkdir -p /etc/pve/firewall
    if [[ ! -f "$cfw" ]]; then
        printf '[OPTIONS]\nenable: 1\npolicy_in: ACCEPT\npolicy_out: ACCEPT\n' > "$cfw"
        ok "Proxmox firewall switched on (allows everything; only the sandbox is restricted)."; changed=1
    elif ! grep -qx 'enable: 1' "$cfw"; then
        # The datacenter default for incoming is DROP; keep the host open unless a policy is set.
        local tmp; tmp=$(mktemp)
        if ! grep -q '^\[OPTIONS\]' "$cfw"; then
            { printf '[OPTIONS]\n\n'; cat "$cfw"; } > "$tmp"
            cat "$tmp" > "$cfw"
        fi
        awk -v pin="$(grep -c '^policy_in:' "$cfw" || true)" -v pout="$(grep -c '^policy_out:' "$cfw" || true)" '
            /^enable:/ { next }
            /^\[OPTIONS\]/ { print; print "enable: 1"
                if (pin == 0) print "policy_in: ACCEPT"
                if (pout == 0) print "policy_out: ACCEPT"
                next }
            { print }' "$cfw" > "$tmp"
        cat "$tmp" > "$cfw"; rm -f "$tmp"   # /etc/pve takes plain writes, not sed -i renames
        ok "Proxmox firewall switched on."; changed=1
    fi
    if is_private "$DNS"; then
        dns_rules="OUT ACCEPT -dest ${DNS} -p udp -dport 53 # dns
OUT ACCEPT -dest ${DNS} -p tcp -dport 53 # dns
"
    fi
    # ipfilter stops the VM from using any other address, so it cannot pose as the gateway or Hermes.
    new="[OPTIONS]
enable: 1
ipfilter: 1
policy_in: DROP
policy_out: ACCEPT

[IPSET ipfilter-net0]
${SB_IP}

[RULES]
IN ACCEPT -source ${NET_CIDR} -p tcp -dport 22 # ssh from LAN (key only)
IN ACCEPT -source ${HERMES_IP} -p tcp -dport ${CDP_PORT} # browser, Hermes only
${dns_rules}OUT DROP -dest 10.0.0.0/8 # private
OUT DROP -dest 172.16.0.0/12 # private
OUT DROP -dest 192.168.0.0/16 # private
OUT DROP -dest ${NET_CIDR} # this LAN, even if public
OUT DROP -dest 100.64.0.0/10 # tailscale
OUT DROP -dest 169.254.0.0/16 # link-local
OUT DROP -dest 224.0.0.0/4 # multicast
OUT DROP -dest 255.255.255.255 # broadcast
OUT DROP -dest ::/0 # no IPv6: link-local would reach the LAN"
    old=$(cat "/etc/pve/firewall/${VMID}.fw" 2>/dev/null || true)
    if [[ "$new" != "$old" ]]; then printf '%s\n' "$new" > "/etc/pve/firewall/${VMID}.fw"; changed=1; fi
    if (( changed )) || ! pve-firewall status 2>/dev/null | grep -q 'enabled/running'; then
        pve-firewall restart >/dev/null 2>&1 || true
        sleep 3
    fi
    pve-firewall status 2>/dev/null | grep -q 'enabled/running' || fail "The Proxmox firewall did not start. Check: pve-firewall status"
    ok "Firewall rules for VM $VMID in place."
}

sb_ssh() {
    ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "${VM_USER}@${SB_IP}" "$@"
}

start_and_wait() {
    [[ "$(qm status "$VMID" | awk '{print $2}')" == "running" ]] || qm start "$VMID" >/dev/null
    info "Waiting for the sandbox (a first boot takes 1-3 minutes)..."
    local t=0
    until sb_ssh true 2>/dev/null; do
        sleep 5; t=$((t + 5))
        (( t > 600 )) && fail "The sandbox did not answer SSH within 10 minutes. See $LOG_FILE"
    done
    ok "Sandbox is up at ${SB_IP}."
}

# Runs inside the VM as root. Safe to repeat.
provision() {
    info "Installing Docker, Chrome and the browser service (3-6 minutes)..."
    sb_ssh "sudo bash -s -- '$VM_USER' '$SB_IP' '$CDP_PORT'" <<'REMOTE' || fail "Sandbox setup failed. See $LOG_FILE"
set -euo pipefail
U="$1"; IP="$2"; PORT="$3"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
cloud-init status --wait >/dev/null 2>&1 || true
APT="apt-get -o DPkg::Lock::Timeout=600"   # apt-daily holds the lock on a fresh VM
$APT update -qq >/dev/null
$APT install -y -qq qemu-guest-agent docker.io socat curl wget jq git unzip python3-venv >/dev/null
systemctl enable --now qemu-guest-agent docker >/dev/null 2>&1 || true
usermod -aG docker "$U"
if ! command -v google-chrome >/dev/null; then
  wget -q -O /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  $APT install -y -qq /tmp/chrome.deb >/dev/null
  rm -f /tmp/chrome.deb
fi

changed=0
put() { # put <file> <content>: write only when different
  if ! printf '%s\n' "$2" | cmp -s - "$1" 2>/dev/null; then printf '%s\n' "$2" > "$1"; changed=1; fi
}
put /etc/systemd/system/chrome-cdp.service "[Unit]
Description=Headless Chrome for Hermes (CDP)
After=network-online.target
[Service]
User=$U
ExecStart=/usr/bin/google-chrome --headless=new --no-first-run --no-default-browser-check --disable-gpu --remote-debugging-port=9222 --user-data-dir=/home/$U/.chrome-agent --window-size=1366,900 about:blank
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target"
put /etc/systemd/system/cdp-proxy.service "[Unit]
Description=Expose Chrome CDP to Hermes
After=chrome-cdp.service network-online.target
[Service]
User=$U
ExecStart=/usr/bin/socat TCP-LISTEN:$PORT,fork,reuseaddr,bind=$IP TCP:127.0.0.1:9222
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target"
systemctl daemon-reload
systemctl enable --now chrome-cdp cdp-proxy >/dev/null 2>&1
(( changed )) && systemctl restart chrome-cdp cdp-proxy

ssh_changed=0
want=$'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no'
if ! printf '%s\n' "$want" | cmp -s - /etc/ssh/sshd_config.d/01-hardening.conf 2>/dev/null; then
  printf '%s\n' "$want" > /etc/ssh/sshd_config.d/01-hardening.conf; ssh_changed=1
fi
sshd -t
# With socket activation each login reads the config anew, so a failed reload is harmless.
(( ssh_changed )) && { systemctl reload ssh 2>/dev/null || true; }

for _ in $(seq 1 20); do
  curl -fs "http://$IP:$PORT/json/version" | grep -q '"Browser"' && exit 0
  sleep 2
done
echo "Chrome did not start" >&2; exit 1
REMOTE
    ok "Docker, Chrome and the browser service are ready."
}

hermes_conf_md5() { pct exec "$CTID" -- sh -c "cat '${HERMES_DATA}/config.yaml' '${HERMES_DATA}/.env' 2>/dev/null | md5sum"; }

restart_hermes() {
    info "Restarting Hermes to apply..."
    pct exec "$CTID" -- docker restart hermes >/dev/null || fail "Could not restart Hermes (CT $CTID)."
    local t=0
    until hermes_running; do sleep 3; t=$((t + 3)); (( t > 90 )) && fail "Hermes did not restart."; done
    sleep 10
}

# Value of a key under terminal: in Hermes' config.yaml.
hermes_terminal() {
    pct exec "$CTID" -- awk -v k="$1" '/^terminal:/ {t=1; next} /^[^[:space:]]/ {t=0}
        t && $1 == k":" {print $2; exit}' "${HERMES_DATA}/config.yaml" 2>/dev/null | tr -d "'\"" || true
}
terminal_in_sandbox() {
    [[ "$(hermes_terminal backend)" == ssh ]] \
        && pct exec "$CTID" -- grep -q "^TERMINAL_SSH_HOST=${SB_IP}\$" "${HERMES_DATA}/.env" 2>/dev/null
}

# Point Hermes' browser at the sandbox and store the SSH details for the optional sandbox terminal.
# The terminal stays where it is: Google Workspace, scripts and cron jobs need Hermes' own files.
wire_hermes() {
    local before kh="${HERMES_DATA}/.ssh/known_hosts"
    # A rebuilt sandbox has a new host key; drop the old one so Hermes can connect.
    pct exec "$CTID" -- sh -c "[ -f '$kh' ] && ssh-keygen -q -R '$SB_IP' -f '$kh' >/dev/null 2>&1; rm -f '${kh}.old'; true"
    pct exec "$CTID" -- chown -R "${HERMES_UID}:${HERMES_UID}" "${HERMES_DATA}/.ssh"
    pct exec "$CTID" -- docker exec -u "$HERMES_UID" hermes ssh -i "$HERMES_KEY_IN" -o BatchMode=yes \
        -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/opt/data/.ssh/known_hosts "${VM_USER}@${SB_IP}" true >/dev/null 2>&1 \
        || fail "Hermes cannot log in to the sandbox. See $LOG_FILE"

    before=$(hermes_conf_md5)
    { hx config set TERMINAL_SSH_HOST "$SB_IP" \
        && hx config set TERMINAL_SSH_USER "$VM_USER" \
        && hx config set TERMINAL_SSH_KEY "$HERMES_KEY_IN" \
        && hx config set browser.cdp_url "http://${SB_IP}:${CDP_PORT}"; } >/dev/null \
        || fail "Could not change Hermes' settings. See $LOG_FILE"
    if terminal_in_sandbox; then
        hx config set terminal.cwd "/home/${VM_USER}" >/dev/null || fail "Could not change Hermes' settings."
    fi
    if [[ "$before" != "$(hermes_conf_md5)" ]]; then
        restart_hermes
        ok "Hermes now opens web pages in the sandbox."
    else
        ok "Hermes already uses the sandbox browser."
    fi
}

hermes_wired() {
    pct exec "$CTID" -- grep -qE "^[[:space:]]+cdp_url: .*${SB_IP}:${CDP_PORT}" "${HERMES_DATA}/config.yaml" 2>/dev/null
}

# Terminal back in Hermes' container; a cwd inside the sandbox would break every command there.
terminal_to_hermes_settings() {
    hx config set terminal.backend local >/dev/null || return 1
    [[ "$(hermes_terminal cwd)" == "/home/${VM_USER}" ]] && { hx config set terminal.cwd . >/dev/null || return 1; }
    pct exec "$CTID" -- sed -i 's/^TERMINAL_ENV=ssh$/TERMINAL_ENV=local/' "${HERMES_DATA}/.env"
}

terminal_toggle() {
    need_sandbox
    if terminal_in_sandbox; then
        info "Hermes' terminal runs in the sandbox."
        yes_no "Move it back into Hermes' container (Google, scripts and cron jobs work again)?" || return 0
        terminal_to_hermes_settings || fail "Could not change Hermes' settings."
        restart_hermes
        ok "Hermes' terminal runs in its own container again. The browser stays in the sandbox."
    else
        info "Hermes' terminal runs in its own container (recommended)."
        warn "In the sandbox, the terminal cannot see Hermes' files: Google Workspace (Gmail,"
        echo "       Calendar, Contacts), scripts in its data folder and cron jobs that use them stop working."
        no_yes "Move the terminal into the sandbox anyway?" || return 0
        { hx config set terminal.backend ssh && hx config set terminal.cwd "/home/${VM_USER}"; } >/dev/null \
            || fail "Could not change Hermes' settings."
        restart_hermes
        ok "Hermes' terminal now runs in the sandbox."
    fi
}

# Returns the number of failed checks.
self_test() {
    local bad=0 code
    banner "Self-test"
    if sb_ssh true 2>/dev/null; then ok "Sandbox answers on SSH (${VM_USER}@${SB_IP})."
    else warn "Sandbox does not answer on SSH."; bad=$((bad + 1)); fi

    code=$(sb_ssh "curl -s -m 8 -o /dev/null -w '%{http_code}' https://www.google.com" 2>/dev/null || true)
    if [[ "$code" =~ ^[23] ]]; then ok "Sandbox reaches the internet."
    else warn "Sandbox cannot reach the internet (HTTP ${code:-none})."; bad=$((bad + 1)); fi

    if sb_ssh "curl -sk -m 5 -o /dev/null https://${HOST_IP}:8006" 2>/dev/null; then
        warn "Sandbox can reach your Proxmox host. The LAN block is not working."; bad=$((bad + 1))
    else ok "Sandbox is blocked from your LAN."; fi

    if pct exec "$CTID" -- docker exec -u "$HERMES_UID" hermes ssh -i "$HERMES_KEY_IN" -o BatchMode=yes \
         -o ConnectTimeout=8 -o UserKnownHostsFile=/opt/data/.ssh/known_hosts "${VM_USER}@${SB_IP}" true >/dev/null 2>&1; then ok "Hermes can log in to the sandbox."
    else warn "Hermes cannot log in to the sandbox (choose Install to fix)."; bad=$((bad + 1)); fi

    if pct exec "$CTID" -- docker exec hermes sh -c "P=/opt/hermes/.venv/bin/python; [ -x \$P ] || P=python3; \$P -c \
         \"import urllib.request,sys;sys.exit(b'Browser' not in urllib.request.urlopen('http://${SB_IP}:${CDP_PORT}/json/version',timeout=5).read())\"" \
         >/dev/null 2>&1; then ok "Hermes reaches the sandbox browser."
    else warn "Hermes cannot reach the sandbox browser."; bad=$((bad + 1)); fi

    if curl -s -m 5 -o /dev/null "http://${SB_IP}:${CDP_PORT}/json/version" 2>/dev/null; then
        warn "The sandbox browser is open to the LAN, not only to Hermes."; bad=$((bad + 1))
    else ok "The sandbox browser is closed to everything except Hermes."; fi

    local ll; ll=$(ip -6 -o addr show dev "$BRIDGE" scope link 2>/dev/null | awk '{print $4; exit}' || true); ll="${ll%/*}"
    if [[ -n "$ll" ]]; then
        if sb_ssh "curl -sk -m 5 -o /dev/null 'https://[${ll}%25eth0]:8006' || curl -sk -m 5 -o /dev/null 'https://[${ll}%25ens18]:8006'" 2>/dev/null; then
            warn "Sandbox can reach your Proxmox host over IPv6."; bad=$((bad + 1))
        else ok "Sandbox is blocked from your LAN over IPv6 too."; fi
    fi

    if hermes_wired; then ok "Hermes opens web pages in the sandbox."
    else warn "Hermes is not set to use the sandbox browser (choose Install to fix)."; bad=$((bad + 1)); fi
    if terminal_in_sandbox; then info "Hermes' terminal runs in the sandbox (Settings > Terminal)."
    else info "Hermes' terminal runs in its own container (Settings > Terminal)."; fi
    return "$bad"
}

snapshot_clean() {
    qm listsnapshot "$VMID" 2>/dev/null | grep -qw clean && qm delsnapshot "$VMID" clean >/dev/null
    qm snapshot "$VMID" clean --description "Fresh sandbox, made by setup-hermessb" >/dev/null \
        && ok "Saved restore point 'clean' (used by Reset)." \
        || warn "Could not save a restore point; Reset will not work. Is $STORAGE snapshot-capable?"
}

snapshot_hermes() {
    pct listsnapshot "$CTID" 2>/dev/null | grep -qw pre-sandbox && return 0
    pct snapshot "$CTID" pre-sandbox --description "Hermes before the sandbox, made by setup-hermessb" >/dev/null 2>&1 \
        && ok "Saved restore point 'pre-sandbox' for Hermes." \
        || warn "Could not snapshot Hermes; continuing."
}

summary() {
    banner "Sandbox ready"
    ok "Hermes now opens web pages in the sandbox. Its terminal stays in its own container,"
    echo "       so Gmail, Calendar, Contacts and your scripts keep working (Settings > Terminal to change)."
    echo "       Hermes   : CT $CTID at $HERMES_IP"
    echo "       Sandbox  : VM $VMID ($VM_NAME) at $SB_IP, user $VM_USER"
    echo "       Log      : $LOG_FILE"
    warn "Reserve $HERMES_IP and $SB_IP in your router so it never gives them to another device."
    info "To test it from Telegram, run this again and choose Guide."
}

# --- Actions -----------------------------------------------------------------
choose_settings() {
    VMID=$VMID_DEFAULT
    while vmid_used "$VMID"; do VMID=$((VMID + 1)); done
    info "Looking for a free IP address..."
    SB_IP="$(pick_ip || true)"
    [[ -n "$SB_IP" ]] || warn "No free IP found automatically; you will be asked for one."
    VM_USER=$VM_USER_DEFAULT; CORES=$CORES_DEFAULT; MEMORY_GB=$MEMORY_GB_DEFAULT; DISK_GB=$DISK_GB_DEFAULT
    STORAGE="$(pick_storage)"
    [[ -n "$STORAGE" ]] || fail "No storage for VM disks found."

    banner "Step 1 of 2 - Sandbox settings"
    echo "       VM ID     : $VMID"
    echo "       IP        : ${SB_IP:-(none found)}"
    echo "       User      : $VM_USER"
    echo "       CPU / RAM : $CORES cores / ${MEMORY_GB} GB"
    echo "       Disk      : ${DISK_GB} GB on $STORAGE"
    echo ""
    [[ -n "$SB_IP" ]] && yes_no "Use these recommended settings?" && return 0

    info "Press Enter to keep each value."
    local v
    while :; do
        v=$(ask "VM ID" "$VMID")
        if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 100 )) && ! vmid_used "$v"; then VMID=$v; break; fi
        warn "VM ID must be a free number from 100 up."
    done
    while :; do
        v=$(ask "IP address" "${SB_IP:-}")
        if valid_ip "$v" && in_subnet "$v" && ip_free "$v"; then SB_IP=$v; break; fi
        warn "Use a free address in ${NET_CIDR}."
    done
    while :; do
        v=$(ask "User name" "$VM_USER")
        [[ "$v" =~ ^[a-z][a-z0-9_-]{0,30}$ && "$v" != root ]] && { VM_USER=$v; break; }
        warn "Lowercase letters, digits, - or _, starting with a letter."
    done
    while :; do v=$(ask "CPU cores" "$CORES"); [[ "$v" =~ ^[1-9][0-9]?$ ]] && { CORES=$v; break; }; warn "1 to 99."; done
    while :; do v=$(ask "RAM in GB" "$MEMORY_GB"); [[ "$v" =~ ^[1-9][0-9]?$ ]] && { MEMORY_GB=$v; break; }; warn "1 to 99."; done
    while :; do v=$(ask "Disk in GB" "$DISK_GB"); [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 16 )) && { DISK_GB=$v; break; }; warn "16 or more."; done
}

action_install() {
    detect_host
    detect_hermes
    local existing; existing="$(find_vmid)"
    if [[ -n "$existing" ]]; then
        load_existing "$existing" || fail "Cannot tell the IP or user of VM $existing ($VM_NAME). Uninstall it, then Install."
        STORAGE="$(pick_storage)"
        banner "Repair sandbox"
        info "Sandbox found (VM $VMID at $SB_IP). Each part is checked and fixed; nothing is deleted."
        has_tty && { yes_no "Check and repair it now?" || { info "Cancelled. Nothing changed."; exit 0; }; }
        firewall_precheck
    else
        has_tty || fail "Run this in a terminal: Install asks for confirmation."
        choose_settings
        local free_mb; free_mb=$(free -m | awk '/^Mem:/ {print $7}')
        (( free_mb < MEMORY_GB * 1024 )) && warn "Only ${free_mb} MB RAM free; the sandbox asks for ${MEMORY_GB} GB."
        banner "Step 2 of 2 - Review"
        echo "       Create VM $VMID ($VM_NAME) at $SB_IP with Ubuntu, Docker and Chrome."
        echo "       Firewall: the sandbox reaches the internet but not your LAN."
        echo "       Hermes (CT $CTID) keeps IP $HERMES_IP permanently and restarts once."
        echo "       Hermes' browser moves into the sandbox; its terminal stays (Gmail and scripts keep working)."
        echo "       Takes 5-10 minutes. No more questions after this."
        echo ""
        firewall_precheck
        yes_no "Proceed?" || { info "Cancelled. Nothing changed."; exit 0; }
    fi

    pin_hermes_ip
    ensure_hermes_key
    if [[ -z "$existing" ]]; then
        fetch_image
        create_vm
    else
        ensure_vm_firewall_nic
    fi
    write_firewall
    start_and_wait
    [[ -n "$existing" ]] && authorize_hermes_key
    provision
    snapshot_hermes
    wire_hermes
    local bad=0
    self_test || bad=$?
    if (( bad )); then
        warn "$bad check(s) failed. Fix the cause and choose Install again; it repairs in place."
        exit 1
    fi
    # A repaired sandbox keeps its restore point: it may already hold Hermes' work.
    if [[ -z "$existing" ]] || ! qm listsnapshot "$VMID" 2>/dev/null | grep -qw clean; then
        snapshot_clean
    fi
    summary
}

need_sandbox() {
    detect_host
    detect_hermes
    local id; id="$(find_vmid)"
    [[ -n "$id" ]] || fail "No sandbox yet. Choose Install."
    load_existing "$id" || fail "Cannot tell the IP or user of VM $id ($VM_NAME). Uninstall it, then Install."
}

action_status() {
    need_sandbox
    banner "Status"
    info "Sandbox VM $VMID ($VM_NAME) at $SB_IP: $(qm status "$VMID" | awk '{print $2}')"
    info "Hermes CT $CTID at $HERMES_IP"
    local snap; snap=$(qm listsnapshot "$VMID" 2>/dev/null | grep -w clean | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]+' | head -1 || true)
    info "Restore point 'clean': ${snap:-missing (choose Install to recreate)}"
    self_test || warn "Some checks failed. Choose Install to repair, or Reset to start the sandbox fresh."
}

action_guide() {
    detect_host
    CTID="$(find_ctid || true)"
    [[ -n "$CTID" ]] && HERMES_IP="$(ct_ip "$CTID")"
    local id; id="$(find_vmid)"
    [[ -n "$id" ]] && { load_existing "$id" || true; }
    banner "Guide"
    info "Addresses"
    echo "       Proxmox host : ${HOST_IP}"
    echo "       Hermes       : ${CTID:+CT $CTID at }${HERMES_IP:-not installed}"
    echo "       Sandbox      : ${id:+VM $id at }${SB_IP:-not installed}"
    echo "       Reserve the Hermes and sandbox IPs in your router so they never change hands."
    echo ""
    info "Log in to the sandbox"
    echo "       Proxmox web UI > your node > Shell, then:  ssh ${VM_USER:-toor}@${SB_IP:-<sandbox-ip>}"
    echo "       No password: it uses this host's key. The VM console has no password on purpose."
    echo ""
    info "Test from Telegram (send /new first)"
    echo "       1. Use your browser tool to open https://www.whatismybrowser.com and tell me the user agent."
    echo "          Expect: HeadlessChrome"
    echo "       2. Run hostname && whoami && pwd in your terminal and tell me the output."
    echo "          Expect: Hermes' own container by default; ${VM_NAME}, ${VM_USER:-toor} if Settings > Terminal is set to the sandbox."
    echo ""
    info "Terminal: Hermes or sandbox"
    echo "       By default only the browser runs in the sandbox. Web pages are where most attacks on"
    echo "       agents come from, and the terminal needs Hermes' own files: Google Workspace (Gmail,"
    echo "       Calendar, Contacts), scripts in its data folder and the cron jobs that run them."
    echo "       Settings > Terminal moves the terminal into the sandbox if you use none of those."
    echo ""
    info "Reset"
    echo "       Hermes can install or break anything in the sandbox. Choose Reset to roll it back"
    echo "       to the fresh state in about a minute. Hermes' memory and settings are not touched."
    echo ""
    info "User name"
    echo "       The sandbox user is ${VM_USER:-toor}. Renaming it touches six places (sudo, home folder,"
    echo "       browser service, browser profile, Hermes config, SSH key), so the clean way is"
    echo "       Uninstall, then Install and answer n to the recommended settings to pick a new name."
    echo "       It takes about 5 minutes; the sandbox holds nothing worth keeping."
    echo ""
    info "Hermes dashboard password"
    echo "       Run setup-hermes.sh and choose Dashboard login."
    echo ""
}

action_reset() {
    need_sandbox
    qm listsnapshot "$VMID" 2>/dev/null | grep -qw clean || fail "No restore point 'clean'. Choose Install to recreate it."
    warn "Everything Hermes did inside the sandbox since it was set up will be erased."
    yes_no "Reset the sandbox?" || { info "Cancelled."; return 0; }
    qm rollback "$VMID" clean >/dev/null || fail "Rollback failed. See $LOG_FILE"
    start_and_wait
    ok "Sandbox reset."
    self_test || warn "Some checks failed. Choose Install to repair."
}

hermes_local() {
    terminal_to_hermes_settings || return 1
    pct exec "$CTID" -- sed -i -E '/^[[:space:]]+cdp_url:/d' "${HERMES_DATA}/config.yaml" || return 1
    restart_hermes
}

action_disconnect() {
    need_sandbox
    hermes_wired || terminal_in_sandbox || { info "Hermes is not using the sandbox. Nothing to do."; return 0; }
    warn "Hermes' browser (and terminal, if moved) go back into its own container, without the LAN block."
    yes_no "Disconnect Hermes from the sandbox?" || { info "Cancelled."; return 0; }
    hermes_local
    ok "Hermes disconnected. The sandbox VM is kept; choose Install to reconnect."
}

action_uninstall() {
    detect_host
    VMID="$(find_vmid)"
    [[ -n "$VMID" ]] || { info "No sandbox found. Nothing to do."; return 0; }
    detect_hermes_soft
    load_existing "$VMID" || true
    warn "This deletes VM $VMID ($VM_NAME), its firewall rules and its restore point."
    echo "       Hermes goes back to browsing (and running commands) in its own container."
    echo "       Hermes' memory, skills and settings are kept. Its 'pre-sandbox' restore point is removed."
    local c=""
    has_tty && { read -rp "  Type 'yes' to confirm: " c </dev/tty || c=""; }
    [[ "$c" == "yes" ]] || { info "Cancelled."; return 0; }
    if [[ -n "$CTID" && -n "$SB_IP" ]] && { hermes_wired || terminal_in_sandbox; }; then
        hermes_local || fail "Could not switch Hermes back to its own container; the sandbox is kept."
        ok "Hermes disconnected."
    fi
    qm stop "$VMID" >/dev/null 2>&1 || true
    qm destroy "$VMID" --purge >/dev/null || fail "Could not delete VM $VMID."
    rm -f "/etc/pve/firewall/${VMID}.fw"
    pve-firewall restart >/dev/null 2>&1 || true
    [[ -n "$SB_IP" ]] && { ssh-keygen -q -R "$SB_IP" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true; }
    if [[ -n "$CTID" ]]; then
        pct exec "$CTID" -- sh -c "rm -f '$HERMES_KEY' '${HERMES_KEY}.pub'; [ -n '$SB_IP' ] && [ -f '${HERMES_DATA}/.ssh/known_hosts' ] && ssh-keygen -q -R '$SB_IP' -f '${HERMES_DATA}/.ssh/known_hosts' >/dev/null 2>&1; rm -f '${HERMES_DATA}/.ssh/known_hosts.old'; true"
        if pct listsnapshot "$CTID" 2>/dev/null | grep -qw pre-sandbox; then pct delsnapshot "$CTID" pre-sandbox >/dev/null 2>&1 || true; fi
    fi
    rm -f "$IMG_FILE"
    ok "Sandbox removed. The Proxmox firewall stays on; with no sandbox it restricts nothing new."
}

settings_menu() {
    while true; do
        banner "Sandbox settings"
        menu "Terminal|where Hermes runs commands: its container or the sandbox" \
            "Shortcut|[$(shortcut_state)]  type '$(shortcut_name)' in a new shell" "Back"
        case "$CHOICE" in
            Terminal) terminal_toggle ;;
            Shortcut) shortcut_toggle ;;
            Back)     return 0 ;;
        esac
    done
}

# --- Main --------------------------------------------------------------------
case "${1:-}" in
    install)   action_install; exit 0 ;;
    uninstall) action_uninstall; exit 0 ;;
esac

while true; do
    banner "Hermes Sandbox"
    id="$(find_vmid)"
    if [[ -n "$id" ]]; then ok "Installed: VM $id at $(vm_ip "$id")"
    else info "Not installed. Gives Hermes its own computer for web browsing, cut off from your LAN."; fi
    menu "Install|create the sandbox, or repair it" "Status|run the self-test" "Guide|IPs, login, Telegram tests" \
        "Reset|roll the sandbox back to fresh" "Disconnect|Hermes stops using the sandbox" \
        "Uninstall|delete the sandbox" "Settings"
    case "$CHOICE" in
        Install)    action_install; exit 0 ;;
        Status)     action_status ;;
        Guide)      action_guide ;;
        Reset)      action_reset ;;
        Disconnect) action_disconnect ;;
        Uninstall)  action_uninstall ;;
        Settings)   settings_menu ;;
    esac
done
