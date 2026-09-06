#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/vm-report.sh?$(date +%s))"
# Purpose: Dump a full guest (VM or LXC) configuration/health report to a text file (Debian/Ubuntu)
# =============================================================================
# Usage:
#   vm-report.sh [output-file]       # default: ./vm-report.txt
#
# Environment:
#   SECTION_TIMEOUT=90   seconds any single section may run before it is
#                        abandoned (a dead NFS/CIFS/virtiofs mount otherwise
#                        hangs df indefinitely)
#
# Companion to pve-report.sh: that one describes the host, this one describes
# what a guest actually got and what is running inside it — virtualisation
# type, passthrough GPU, disks, network, Docker, Ollama, services, logs.
# Re-running is safe: the report file is regenerated fresh each time.
# =============================================================================

set -euo pipefail
export LC_ALL=C

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

SECTION_TIMEOUT="${SECTION_TIMEOUT:-90}"

_await() {
    local pid="$1" limit="$2" ticks=0
    while kill -0 "$pid" 2>/dev/null; do
        if (( ticks >= limit * 5 )); then
            kill -TERM "$pid" 2>/dev/null || true
            pkill -TERM -P "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
        ticks=$(( ticks + 1 ))
    done
    wait "$pid"
}

section() { { echo ""; echo "========== $* =========="; } >>"$OUT"; }
collect() {
    local label="$1"; shift
    local tmp rc=0 pid
    section "$label"
    tmp=$(mktemp "$_WORKDIR/section.XXXXXX")
    { set +e; "$@" >"$tmp" 2>&1; } &
    pid=$!
    _await "$pid" "$SECTION_TIMEOUT" || rc=$?
    cat "$tmp" >>"$OUT"
    case "$rc" in
        0)   ok "$label" ;;
        124) echo "(timed out after ${SECTION_TIMEOUT}s — output above may be partial)" >>"$OUT"
             warn "$label — timed out after ${SECTION_TIMEOUT}s" ;;
        *)   echo "(unavailable or command failed)" >>"$OUT"
             warn "$label — unavailable, skipped" ;;
    esac
}

has() { command -v "$1" &>/dev/null; }

# Print "$body" or a placeholder when empty.
show() { local body="$1" empty="$2"; echo "${body:-$empty}"; }

virt_type() { systemd-detect-virt 2>/dev/null || echo "unknown"; }
is_container() { [[ "$(systemd-detect-virt -c 2>/dev/null || true)" != "none" && -n "$(systemd-detect-virt -c 2>/dev/null || true)" ]]; }

# Real disks only (containers usually have none).
list_disks() {
    lsblk -dno NAME,TYPE 2>/dev/null |
        awk '$2 == "disk" && $1 !~ /^(zram|loop|ram|sr|fd|dm-)/ { print "/dev/" $1 }'
}

pending_reboot() {
    if [[ -f /var/run/reboot-required ]]; then
        echo "reboot-required flag set$( [[ -f /var/run/reboot-required.pkgs ]] && printf ' (%s)' "$(paste -sd, /var/run/reboot-required.pkgs)" )"
        return 0
    fi
    local running newest
    running=$(uname -r)
    newest=$(ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
    [[ -n "$newest" && "$newest" != "$running" ]] || return 1
    echo "running $running, newest installed $newest"
}

gpu_present() { lspci 2>/dev/null | grep -qiE 'VGA|3D controller|Display controller'; }

# --- Health summary ----------------------------------------------------------
sec_summary() {
    local issues=() line n up os

    os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")
    up=$(uptime -p 2>/dev/null || uptime || true)

    echo "---- At a glance ----"
    printf '%-24s %s\n' "OS:"             "${os:-(unknown)}"
    printf '%-24s %s\n' "Kernel:"         "$(uname -r)"
    printf '%-24s %s\n' "Virtualisation:" "$(virt_type)"
    printf '%-24s %s\n' "Uptime:"         "${up:-(unknown)}"
    printf '%-24s %s\n' "CPUs:"           "$(nproc 2>/dev/null || echo '?')"
    printf '%-24s %s\n' "Memory:"         "$(free -h 2>/dev/null | awk '/^Mem:/ { print $2 " total, " $7 " available" }')"
    printf '%-24s %s\n' "Root disk:"      "$(df -h / 2>/dev/null | awk 'NR==2 { print $2 " total, " $4 " free (" $5 " used)" }')"
    printf '%-24s %s\n' "Primary IP:"     "$(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"
    if has nvidia-smi; then
        printf '%-24s %s\n' "GPU:" "$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo '(nvidia-smi failed)')"
    elif gpu_present; then
        printf '%-24s %s\n' "GPU:" "$(lspci 2>/dev/null | grep -iE 'VGA|3D controller' | head -1 | cut -d: -f3- | sed 's/^ //')"
    fi
    if has docker; then
        if docker info &>/dev/null; then
            printf '%-24s %s\n' "Docker containers:" "$(docker ps -q | wc -l) running / $(docker ps -aq | wc -l) total"
        else
            printf '%-24s %s\n' "Docker containers:" "(daemon not reachable)"
        fi
    fi
    if has ollama; then
        n=$( { ollama list 2>/dev/null || true; } | awk 'NR>1' | wc -l)
        printf '%-24s %s\n' "Ollama models:" "$n installed"
    fi

    # Failed units
    line=$(systemctl list-units --failed --no-legend --no-pager 2>/dev/null | wc -l)
    (( ${line:-0} > 0 )) && issues+=("$line failed systemd unit(s) — see SERVICES")

    # Filesystems at 85% or above
    while read -r line; do
        [[ -n "$line" ]] && issues+=("Filesystem $line — see FILESYSTEMS")
    done < <(df -P -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs 2>/dev/null |
             awk 'NR>1 && $5+0 >= 85 { print $6 " at " $5 }' || true)

    # Swap under pressure
    line=$(free 2>/dev/null | awk '/^Swap:/ && $2 > 0 { printf "%d", $3 * 100 / $2 }')
    [[ -n "$line" ]] && (( line >= 50 )) && issues+=("Swap ${line}% used — memory pressure, see MEMORY")

    # Memory nearly exhausted
    line=$(free 2>/dev/null | awk '/^Mem:/ { printf "%d", $7 * 100 / $2 }')
    [[ -n "$line" ]] && (( line < 10 )) && issues+=("Only ${line}% of memory available — see MEMORY")

    # Reboot pending
    line=$(pending_reboot) && issues+=("Reboot pending: $line")

    # Pending upgrades
    n=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
    (( ${n:-0} > 0 )) && issues+=("$n package upgrade(s) pending — see APT")

    # GPU passed through but no driver
    if gpu_present && ! is_container; then
        line=$(lspci -k 2>/dev/null | grep -A3 -iE 'VGA|3D controller' | grep -i 'Kernel driver in use' | head -1 || true)
        [[ -z "$line" ]] && issues+=("GPU present but no kernel driver bound — see GPU")
        lspci 2>/dev/null | grep -qi nvidia && ! has nvidia-smi && issues+=("NVIDIA GPU present but nvidia-smi missing — see GPU")
    fi

    # Guest agent (VMs only)
    if ! is_container && [[ "$(virt_type)" == "kvm" ]]; then
        systemctl is-active qemu-guest-agent &>/dev/null || issues+=("qemu-guest-agent not running — host cannot query IP/shutdown cleanly")
    fi

    # Time sync
    if has timedatectl; then
        timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes || issues+=("Clock not NTP-synchronised — see OS")
    fi

    # Docker containers not healthy
    if has docker; then
        while read -r line; do
            [[ -n "$line" ]] && issues+=("Docker container $line — see DOCKER")
        done < <(docker ps -a --format '{{.Names}} {{.Status}}' 2>/dev/null |
                 awk '$2 != "Up" || /\(unhealthy\)/ { print $1 " is " $2 " " $3 }' || true)
    fi

    # SSH hardening
    if [[ -r /etc/ssh/sshd_config ]]; then
        sshd -T 2>/dev/null | grep -qiE '^permitrootlogin yes' && issues+=("sshd permits root login with password — see USERS & SSH")
    fi

    echo ""
    echo "---- Checks ----"
    if (( ${#issues[@]} == 0 )); then
        echo "No issues detected by the automated checks."
    else
        printf '!! %s\n' "${issues[@]}"
    fi
}

# --- Sections ----------------------------------------------------------------
sec_os() {
    hostnamectl 2>/dev/null | grep -vE 'Icon name|Machine ID|Boot ID|Product UUID' || echo "(hostnamectl unavailable)"
    echo ""
    echo "---- Uptime / load ----"
    uptime
    echo ""
    echo "---- Kernel cmdline ----"
    cat /proc/cmdline 2>/dev/null || echo "(unavailable)"
    echo ""
    echo "---- Boot mode ----"
    if is_container; then echo "container (no bootloader)"
    elif [[ -d /sys/firmware/efi ]]; then echo "UEFI"; else echo "Legacy BIOS"; fi
    echo ""
    echo "---- Reboot status ----"
    local pend
    if pend=$(pending_reboot); then echo "Reboot pending ($pend)"; else echo "No reboot pending"; fi
    echo ""
    echo "---- Time ----"
    timedatectl 2>/dev/null | grep -E 'Local time|Time zone|synchronized|NTP service' || date
    echo ""
    echo "---- Locale ----"
    show "$(grep -Ev '^\s*(#|$)' /etc/default/locale 2>/dev/null | paste -sd' ' -)" "(default)"
}

sec_virt() {
    echo "---- Detected ----"
    printf '%-14s %s\n' "type:"      "$(virt_type)"
    printf '%-14s %s\n' "container:" "$(systemd-detect-virt -c 2>/dev/null || echo none)"
    printf '%-14s %s\n' "vm:"        "$(systemd-detect-virt -v 2>/dev/null || echo none)"
    echo ""
    echo "---- DMI (what the hypervisor presents) ----"
    local f
    for f in sys_vendor product_name product_version bios_vendor bios_version chassis_type; do
        [[ -r /sys/class/dmi/id/$f ]] && printf '%-18s %s\n' "$f:" "$(cat /sys/class/dmi/id/$f)"
    done
    [[ -d /sys/class/dmi/id ]] || echo "(no DMI — container)"
    echo ""
    echo "---- Guest agent ----"
    if is_container; then
        echo "(n/a in a container)"
    else
        printf '%-18s %s\n' "qemu-guest-agent:" "$(systemctl is-active qemu-guest-agent 2>/dev/null || echo 'not installed')"
    fi
    echo ""
    echo "---- Paravirt modules loaded ----"
    show "$(lsmod 2>/dev/null | awk '$1 ~ /^(virtio|vfio|kvm|9p|fuse|virtiofs)/ { print $1 }' | sort | paste -sd' ' -)" "(none)"
    echo ""
    echo "---- Shared / network mounts (virtiofs, 9p, nfs, cifs) ----"
    show "$(findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS -t virtiofs,9p,nfs,nfs4,cifs 2>/dev/null)" "(none)"
    echo ""
    echo "---- CPU flags relevant to guests ----"
    local flags
    flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | tr ' ' '\n' | grep -E '^(hypervisor|vmx|svm|avx2|avx512f|aes|sse4_2)$' | paste -sd' ' -)
    show "$flags" "(none of hypervisor/vmx/svm/avx2/avx512f/aes/sse4_2)"
    echo "  hypervisor = running under a VMM; vmx/svm = nested virt possible; avx* = matters for llama.cpp/CPU inference"
}

sec_cpu() {
    lscpu | grep -vE '^(Flags|Vulnerability)'
    echo ""
    echo "---- Active mitigations ----"
    lscpu | grep '^Vulnerability' | grep -v 'Not affected' || echo "(none applied)"
}

sec_memory() {
    free -h
    echo ""
    echo "---- Swap devices ----"
    show "$(swapon --show 2>/dev/null)" "(no swap)"
    echo ""
    echo "---- Top memory consumers ----"
    ps -eo rss,comm --sort=-rss 2>/dev/null | awk 'NR==1 { print "  RSS(MiB) COMMAND"; next } NR<=11 { printf "%10.0f %s\n", $1/1024, $2 }'
    echo ""
    echo "---- Ballooning ----"
    if compgen -G '/sys/bus/virtio/drivers/virtio_balloon/virtio*' >/dev/null; then
        echo "virtio_balloon driver active (host may reclaim memory)"
    else
        echo "no balloon device (memory fixed)"
    fi
}

sec_gpu() {
    echo "---- PCI display devices ----"
    show "$(lspci -nnk 2>/dev/null | grep -A3 -iE 'VGA|3D controller|Display controller' | grep -vE 'Subsystem|Kernel modules')" "(no GPU visible)"
    echo ""
    if has nvidia-smi; then
        echo "---- nvidia-smi ----"
        nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu,power.draw,pstate --format=csv 2>&1 || true
        echo ""
        echo "---- Processes on GPU ----"
        show "$(nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null)" "(none)"
        echo ""
        echo "---- CUDA / toolkit ----"
        printf '%-22s %s\n' "nvidia-smi CUDA:" "$(nvidia-smi 2>/dev/null | grep -oE 'CUDA Version: [0-9.]+' | head -1 | cut -d' ' -f3 || echo '?')"
        printf '%-22s %s\n' "nvcc:"            "$(nvcc --version 2>/dev/null | grep -oE 'release [0-9.]+' | cut -d' ' -f2 || echo 'not installed')"
        printf '%-22s %s\n' "container toolkit:" "$(nvidia-ctk --version 2>/dev/null | head -1 || echo 'not installed')"
        printf '%-22s %s\n' "persistenced:"    "$(systemctl is-active nvidia-persistenced 2>/dev/null || echo 'inactive')"
    elif lspci 2>/dev/null | grep -qi nvidia; then
        echo "---- NVIDIA ----"
        echo "NVIDIA device present but nvidia-smi not installed (driver missing?)"
        echo ""
    fi
    echo "---- GPU kernel modules ----"
    show "$(lsmod 2>/dev/null | awk '$1 ~ /^(nvidia|nouveau|i915|xe|amdgpu|radeon)/ { print $1 }' | sort | paste -sd' ' -)" "(none)"
    echo ""
    echo "---- /dev nodes ----"
    show "$(ls -l /dev/nvidia* /dev/dri/* 2>/dev/null)" "(none)"
}

sec_filesystems() {
    df -hT -x tmpfs -x devtmpfs -x efivarfs -x squashfs -x overlay
    echo ""
    echo "---- Block devices ----"
    show "$(lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL 2>/dev/null)" "(lsblk unavailable — container)"
    echo ""
    echo "---- /etc/fstab (non-default mounts) ----"
    show "$(grep -Ev '^[[:space:]]*(#|$)' /etc/fstab 2>/dev/null)" "(empty)"
    echo ""
    echo "---- Largest directories under / (top 10, excluding mounts) ----"
    du -xhd1 / 2>/dev/null | sort -rh | head -11 | awk 'NR>1'
    echo ""
    echo "---- Discard / TRIM ----"
    printf '%-18s %s\n' "fstrim.timer:" "$(systemctl is-enabled fstrim.timer 2>/dev/null || echo 'n/a')"
}

sec_lvm() {
    has lvs || { echo "(LVM tools not installed)"; return; }
    echo "---- Physical volumes ----"; show "$(pvs 2>/dev/null)" "(none)"
    echo ""
    echo "---- Volume groups ----";    show "$(vgs 2>/dev/null)" "(none)"
    echo ""
    echo "---- Logical volumes ----";  show "$(lvs 2>/dev/null)" "(none)"
}

sec_smart() {
    is_container && { echo "(n/a in a container)"; return; }
    has smartctl || { echo "(smartctl not installed — virtual disks rarely expose SMART anyway)"; return; }
    local d any=0
    for d in $(list_disks); do
        any=1
        echo "== $d =="
        smartctl -i "$d" 2>/dev/null | grep -Ei '^(Model Number|Device Model|Serial Number|User Capacity)' || echo "(no SMART data — virtual disk)"
        smartctl -H "$d" 2>/dev/null | grep -Ei 'overall-health|SMART Health Status' || true
    done
    (( any )) || echo "(no disks)"
}

GUEST_IF_RE='^(veth|docker|br-|tailscale|cni|flannel|virbr)'
sec_network() {
    echo "---- Interfaces ----"
    ip -br a 2>/dev/null | grep -vE "$GUEST_IF_RE" || echo "(ip unavailable)"
    echo ""
    echo "---- Overlay / container interfaces ----"
    show "$(ip -br a 2>/dev/null | grep -E "$GUEST_IF_RE")" "(none)"
    echo ""
    echo "---- MAC addresses ----"
    ip -br link 2>/dev/null | grep -vE "$GUEST_IF_RE" | awk '{ printf "%-20s %s\n", $1, $3 }' || true
    echo ""
    echo "---- Routes ----"
    ip r 2>/dev/null || echo "(ip unavailable)"
    echo ""
    echo "---- DNS ----"
    if has resolvectl; then
        resolvectl status 2>/dev/null | grep -E 'DNS Servers|DNS Domain|Current DNS' | sort -u
    else
        cat /etc/resolv.conf 2>/dev/null
    fi
    echo ""
    echo "---- Netplan / interfaces config ----"
    local body
    body=$(cat /etc/netplan/*.yaml 2>/dev/null | grep -Ev '^\s*(#|$)')
    [[ -n "$body" ]] || body=$(grep -Ev '^\s*(#|$)' /etc/network/interfaces 2>/dev/null)
    show "$body" "(DHCP / no static config found)"
    echo ""
    echo "---- Listening ports ----"
    show "$(ss -tulpnH 2>/dev/null | awk '{ printf "%-6s %-28s %s\n", $1, $5, $7 }' | sort -u)" "(ss unavailable)"
    echo ""
    echo "---- Firewall ----"
    if has ufw; then ufw status verbose 2>/dev/null | head -20
    elif has nft; then show "$(nft list ruleset 2>/dev/null | head -40)" "(nftables empty)"
    else echo "(no ufw/nft)"; fi
    echo ""
    echo "---- Tailscale ----"
    if has tailscale; then tailscale status --self --peers=false 2>/dev/null || tailscale status 2>&1 | head -3
    else echo "(not installed)"; fi
}

sec_docker() {
    has docker || { echo "(docker not installed)"; return 0; }
    docker info &>/dev/null || { echo "(docker daemon not reachable)"; return 0; }
    docker version --format 'Docker {{.Server.Version}} (API {{.Server.APIVersion}}), {{.Server.Platform.Name}}' 2>/dev/null || true
    echo ""
    echo "---- Containers ----"
    show "$(docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null)" "(none)"
    echo ""
    echo "---- Compose projects ----"
    show "$(docker ps -a --filter label=com.docker.compose.project --format '{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}' 2>/dev/null | sort -u)" "(none)"
    echo ""
    echo "---- Disk usage ----"
    docker system df 2>/dev/null || true
    echo ""
    echo "---- GPU runtime ----"
    docker info --format '{{range $k,$v := .Runtimes}}{{$k}} {{end}}' 2>/dev/null | grep -q nvidia && echo "nvidia runtime registered" || echo "no nvidia runtime (install nvidia-container-toolkit for GPU containers)"
    echo ""
    echo "---- Restart policies not 'always/unless-stopped' ----"
    show "$(docker ps -a --format '{{.Names}}' 2>/dev/null | while read -r c; do
        p=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c" 2>/dev/null)
        [[ "$p" == "always" || "$p" == "unless-stopped" ]] || echo "$c: ${p:-no}"
    done)" "(all containers restart automatically)"
}

sec_llm() {
    echo "---- Ollama ----"
    if has ollama; then
        printf '%-14s %s\n' "version:" "$(ollama --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        printf '%-14s %s\n' "service:" "$(systemctl is-active ollama 2>/dev/null || echo 'not a service')"
        printf '%-14s %s\n' "listening:" "$(ss -tlnH 2>/dev/null | awk '$4 ~ /:11434$/ { print $4 }' | paste -sd' ' - || true)"
        printf '%-14s %s\n' "OLLAMA_HOST:" "$(systemctl show ollama -p Environment --value 2>/dev/null | tr ' ' '\n' | grep OLLAMA_ | paste -sd' ' - || echo '(default, localhost only)')"
        echo ""
        echo "installed models:"
        show "$(ollama list 2>/dev/null | awk 'NR>1')" "  (none)"
        echo ""
        echo "loaded now:"
        show "$(ollama ps 2>/dev/null | awk 'NR>1')" "  (none)"
    else
        echo "(not installed)"
    fi
    echo ""
    echo "---- Other runtimes / tooling ----"
    local t
    for t in python3 uv uvx pip3 node npm llama-server llama-cli vllm docker nvidia-ctk; do
        has "$t" && printf '%-14s %s\n' "$t:" "$("$t" --version 2>&1 | head -1)"
    done
    echo ""
    echo "---- Model storage ----"
    local d
    for d in /usr/share/ollama/.ollama/models "$HOME/.ollama/models" /root/.ollama/models "$HOME/.cache/huggingface" /var/lib/ollama; do
        [[ -d "$d" ]] && printf '%-40s %s\n' "$d" "$(du -sh "$d" 2>/dev/null | cut -f1)"
    done
    return 0
}

sec_services() {
    echo "---- Failed units ----"
    systemctl --failed --no-pager 2>/dev/null || true
    echo ""
    echo "---- Key services ----"
    local s st
    for s in ssh sshd docker containerd ollama qemu-guest-agent tailscaled cloudflared nvidia-persistenced unattended-upgrades cron fail2ban; do
        st=$(systemctl is-active "$s" 2>/dev/null || true)
        [[ "$st" == "inactive" && "$(systemctl is-enabled "$s" 2>/dev/null || true)" == "" ]] && continue
        [[ -n "$st" ]] && printf '%-22s %s\n' "$s" "$st"
    done
    true
    echo ""
    echo "---- Enabled services (non-distro) ----"
    show "$(systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null |
        awk '{print $1}' | grep -vE '^(systemd|dbus|getty|serial-getty|networkd|resolved|cron|rsyslog|ssh|sshd|apparmor|e2scrub|snapd|ufw|lvm2|multipathd|open-iscsi|iscsid|blk-availability|console-setup|keyboard-setup|setvtrgb|finalrd|thermald|udisks2|polkit|ModemManager|unattended-upgrades|apport|cloud-|pollinate|fwupd|irqbalance|plymouth|secureboot|ua-|ubuntu-|dmesg|grub|open-vm|qemu-guest|apt-)' |
        paste -sd' ' -)" "(none beyond distro defaults)"
    echo ""
    echo "---- Timers ----"
    show "$(systemctl list-timers --no-pager --no-legend 2>/dev/null | awk '{ printf "%-32s next %s %s\n", $NF, $1, $2 }' | head -15)" "(unavailable)"
}

sec_apt() {
    local f body
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [[ -f "$f" ]] || continue
        body=$(grep -Ev '^[[:space:]]*(#|$)' "$f" || true)
        [[ -n "$body" ]] || continue
        echo "---- $f ----"
        echo "$body"
        echo ""
    done
    echo "---- Unattended upgrades ----"
    show "$(grep -Ehv '^\s*(//|$)' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)" "(not configured)"
    echo ""
    echo "---- Pending upgrades ----"
    show "$(apt list --upgradable 2>/dev/null | tail -n +2)" "(none — system up to date)"
    echo ""
    echo "---- Last apt activity ----"
    show "$(grep -hE '^(Start-Date|Commandline)' /var/log/apt/history.log 2>/dev/null | tail -4)" "(no history)"
}

sec_users() {
    echo "---- Login-capable users ----"
    awk -F: '$7 !~ /(nologin|false|sync)$/ && ($3 == 0 || $3 >= 1000) { printf "%-16s uid=%-6s shell=%s\n", $1, $3, $7 }' /etc/passwd
    echo ""
    echo "---- sudo / admin group ----"
    show "$(getent group sudo wheel admin 2>/dev/null | awk -F: '$4 != "" { print $1 ": " $4 }')" "(no members)"
    echo ""
    echo "---- SSH authorized keys ----"
    local h u
    for h in /root $(awk -F: '$3 >= 1000 && $7 !~ /nologin|false/ { print $6 }' /etc/passwd); do
        [[ -r "$h/.ssh/authorized_keys" ]] || continue
        u=$(basename "$h"); [[ "$h" == /root ]] && u=root
        printf '%-16s %s key(s)\n' "$u" "$(grep -cE '^(ssh-|ecdsa-|sk-)' "$h/.ssh/authorized_keys" || true)"
    done
    echo ""
    echo "---- sshd effective settings ----"
    show "$(sshd -T 2>/dev/null | grep -iE '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|allowusers|x11forwarding) ')" "(sshd not available)"
    echo ""
    echo "---- Recent logins ----"
    show "$(last -n 8 -w 2>/dev/null | grep -vE '^(reboot|wtmp|$)')" "(none)"
}

sec_logs() {
    local dedup recent
    dedup=$(journalctl -p 3 -b --no-pager -o short-iso 2>/dev/null |
        grep -v '^-- ' |
        cut -d' ' -f3- |
        sed -E 's/\[[0-9]+\]:/:/; s/0x[0-9a-f]+/0xN/g; s/\b[0-9]+\b/N/g' |
        sort | uniq -c | sort -rn | head -20 || true)
    echo "---- Errors since boot (count × message, numbers normalised) ----"
    show "$dedup" "(no errors logged this boot)"
    echo ""
    echo "---- Most recent errors (last 10, verbatim) ----"
    recent=$(journalctl -p 3 -b --no-pager 2>/dev/null | grep -v '^-- ' | tail -10 || true)
    show "$recent" "(none)"
    echo ""
    echo "---- OOM kills this boot ----"
    show "$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|Killed process' | tail -5)" "(none)"
    echo ""
    echo "---- Last boot reason ----"
    show "$(journalctl --list-boots --no-pager 2>/dev/null | tail -3)" "(unavailable)"
}

sec_perf() {
    echo "---- Load ----"
    cat /proc/loadavg
    echo ""
    echo "---- Top CPU consumers ----"
    ps -eo pcpu,comm --sort=-pcpu 2>/dev/null | awk 'NR==1 { print "  %CPU COMMAND"; next } NR<=8 { printf "%6.1f %s\n", $1, $2 }'
    echo ""
    echo "---- Root disk buffered read (quick, 512 MiB) ----"
    local dev
    dev=$(findmnt -no SOURCE / 2>/dev/null || true)
    if has dd && [[ -n "$dev" && -b "$dev" && -r "$dev" ]]; then
        dd if="$dev" of=/dev/null bs=1M count=512 iflag=direct 2>&1 | tail -1 || echo "(read failed)"
    else
        echo "(skipped — root device not directly readable)"
    fi
}

# --- Pre-flight --------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
[[ -f /etc/os-release ]] || fail "No /etc/os-release — is this a Linux guest?"

OUT="${1:-vm-report.txt}"
_OUTDIR=$(dirname -- "$OUT")
[[ -d "$_OUTDIR" ]] || fail "Output directory does not exist: $_OUTDIR"
[[ -w "$_OUTDIR" ]] || fail "Output directory is not writable: $_OUTDIR"
[[ ! -e "$OUT" || -w "$OUT" ]] || fail "Output file is not writable: $OUT"

_WORKDIR=$(mktemp -d)
trap 'rm -rf "$_WORKDIR"' EXIT

# --- Generate report ---------------------------------------------------------
info "Writing guest report to: $OUT"
{
    echo "==================== GUEST REPORT: $(date) ===================="
    echo "Hostname: $(hostname)   Virtualisation: $(virt_type)"
} >"$OUT"

collect "HEALTH SUMMARY"   sec_summary
collect "OS"               sec_os
collect "VIRTUALISATION"   sec_virt
collect "CPU"              sec_cpu
collect "MEMORY"           sec_memory
collect "GPU"              sec_gpu
collect "FILESYSTEMS"      sec_filesystems
collect "LVM"              sec_lvm
collect "SMART"            sec_smart
collect "NETWORK"          sec_network
collect "DOCKER"           sec_docker
collect "LLM STACK"        sec_llm
collect "SERVICES"         sec_services
collect "APT"              sec_apt
collect "USERS & SSH"      sec_users
collect "LOGS"             sec_logs
collect "PERFORMANCE"      sec_perf

{ echo ""; echo "==================== END OF REPORT ===================="; } >>"$OUT"

# Hand the file back to the invoking user so it is readable/deletable without sudo.
[[ -n "${SUDO_USER:-}" ]] && chown "$SUDO_USER" "$OUT" 2>/dev/null || true

ok "Report complete: $(realpath "$OUT" 2>/dev/null || echo "$OUT")"
info "Contains IPs, MACs, usernames and open ports — review before sharing."
