#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/lvm-setup.sh?$(date +%s))"
# Purpose: Grow the root logical volume to fill all free space in its volume group
# =============================================================================
# Idempotent: if the root filesystem is not on LVM, or there is no meaningful
# free space (< 1 GiB) in the volume group, it reports that and exits 0 (no-op).
# =============================================================================

set -euo pipefail

info()  { echo "[*] $*"; }
ok()    { echo "[+] $*"; }
warn()  { echo "[!] $*"; }
fail()  { echo "[x] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

echo ""
echo "LVM Root Expansion"
echo "================================================="
echo ""

# Detect the device backing /
lv=$(findmnt -n -o SOURCE / 2>/dev/null || true)
if [[ -z "$lv" ]]; then
    warn "Could not detect root device. Skipping LVM expansion."
    exit 0
fi

# Only proceed if it's an LVM logical volume
if ! lvdisplay "$lv" &>/dev/null 2>&1; then
    info "Root filesystem is not on LVM (${lv}). Nothing to do."
    exit 0
fi

# How much free space is in the VG?
vg=$(lvs --noheadings -o vg_name "$lv" 2>/dev/null | tr -d ' ')
free_pe=$(vgs --noheadings --units b -o vg_free "$vg" 2>/dev/null | tr -d ' B' || echo 0)
free_gib=$(( free_pe / 1073741824 ))

if (( free_gib < 1 )); then
    ok "No significant free space in VG '${vg}' (${free_gib} GiB). Nothing to do."
    exit 0
fi

info "Expanding root LV to claim ${free_gib} GiB free in VG '${vg}'..."

if lvextend -l +100%FREE "$lv"; then
    ok "Logical volume extended."
else
    warn "lvextend failed (may already be at max). Nothing further to do."
    exit 0
fi

if resize2fs "$lv"; then
    ok "Filesystem resized. Root is now $(df -h / | awk 'NR==2{print $2}')."
else
    warn "resize2fs failed. You may need to resize the filesystem manually."
fi

echo ""
ok "Done."
echo ""
