#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/llama-setup.sh?$(date +%s))"
# Purpose: Local LLM server (llama.cpp + Qwen on the GPU) inside the Ubuntu VM, as an OpenAI-compatible API for Hermes
# =============================================================================
# Usage (run inside the GPU VM, e.g. VM 200 — not on the Proxmox host or in an LXC):
#   (no args)        menu
#   install [-y]     install or repair everything, then test   (-y = no questions)
#   status           service, GPU memory, speed, address and key for Hermes
#   test             one real tool-calling request + speed measurement
#   update           newest llama.cpp release (model and settings untouched)
#   thinking on|off  model thinks before answering (smarter) or not (faster)
#   new-key          replace the API key; prints the one command Hermes needs
#   uninstall        remove server + settings; asks separately about the model file
#
# What install does (safe to re-run, finished steps are skipped):
#   1. NVIDIA driver          -> gpu-setup.sh driver        (reboot once if freshly installed)
#   2. Model storage          -> virtiofs-setup.sh mount    (/mnt/sec, the host's big drive)
#      model file  : /mnt/sec/models/<model>/      (shared asset, survives a VM rebuild)
#      settings    : /etc/llama/env on the VM, with a copy in /mnt/sec/apps/llama/
#                    so the API key and tuning come back after a VM rebuild (Hermes keeps working)
#   3. llama.cpp              -> prebuilt CUDA release, falls back to building from source
#   4. Model download         -> Hugging Face, resumable, size-verified (~22 GB)
#   5. GPU/RAM split          -> tries settings until the model fits the GPU with 64K context
#   6. systemd service        -> service "llama" on port 8080, API key in /etc/llama/env
#   7. Test                   -> tool call must come back, context must be 64K
#
# Config (env): LLM_PORT=8080  LLM_CTX=65536  LLM_QUANT=UD-Q4_K_XL (or UD-Q3_K_XL: smaller,
#   faster, slightly less accurate)  LLM_THINKING=off (default, faster) or on (smarter, slower)  VIRTIOFS_TAG=sec  MOUNT_POINT=/mnt/sec
# Hermes needs at least 64K context; do not lower LLM_CTX below 65536.
# =============================================================================

set -euo pipefail

# --- Helpers -----------------------------------------------------------------
# >>> admonition (managed by scripts/sync-admonition.sh — do not edit here) >>>
if [[ -n "${FORCE_COLOR:-}" || -t 1 ]]; then
  _CK=$'\033[1;32m'; _CI=$'\033[1;36m'; _CW=$'\033[1;33m'; _CE=$'\033[1;31m'; _C0=$'\033[0m'
else
  _CK=''; _CI=''; _CW=''; _CE=''; _C0=''
fi
ok()   { printf '%s[ OK ]%s %s\n' "$_CK" "$_C0" "$*"; }
info() { printf '%s[INFO]%s %s\n' "$_CI" "$_C0" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$_CW" "$_C0" "$*" >&2; }
fail() { printf '%s[FAIL]%s %s\n' "$_CE" "$_C0" "$*" >&2; exit 1; }
# <<< admonition <<<

hr() { echo "================================================================"; }

# Strict mode stops on any unexpected error; say so plainly instead of going quiet.
trap 'printf "%s[FAIL]%s Stopped unexpectedly (line %s). Re-run the same command; finished steps are skipped. If it happens again, send this screen.\n" "$_CE" "$_C0" "$LINENO" >&2' ERR

# Yes/no prompt that works under: bash -c "$(wget ...)". -y answers yes to all.
YES=0
ask_yn() { # ask_yn "question" default(y|n)
    local q="$1" def="${2:-n}" a
    [[ "$YES" == "1" ]] && return 0
    if [[ -r /dev/tty ]]; then
        read -rp "  ${q} [$( [[ $def == y ]] && echo Y/n || echo y/N )]: " a </dev/tty || a=""
    else
        a=""
    fi
    a="${a:-$def}"
    [[ "${a,,}" == "y" || "${a,,}" == "yes" ]]
}

# --- Config ------------------------------------------------------------------
PORT="${LLM_PORT:-8080}"
CTX="${LLM_CTX:-65536}"                 # Hermes rejects anything below 64K
QUANT="${LLM_QUANT:-UD-Q4_K_XL}"
THINKING="${LLM_THINKING:-off}"        # off = fast replies; judgement work goes to Claude anyway
VIRTIOFS_TAG="${VIRTIOFS_TAG:-sec}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/sec}"

HF_REPO="unsloth/Qwen3.6-35B-A3B-GGUF"
MODEL_ALIAS="qwen3.6-35b-a3b"
MODEL_FILE_NAME="Qwen3.6-35B-A3B-${QUANT}.gguf"
MIN_FREE_GB=30

APP_DIR="/opt/llama"             # binaries: $APP_DIR/releases/<tag>, $APP_DIR/current -> active
CONF_DIR="/etc/llama"
ENV_FILE="$CONF_DIR/env"
SERVICE="llama"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
TUNE_LOG="/var/log/llama-setup-tune.log"
TEST_PORT=18080

GITHUB_BASE="https://github.com/therepos/proxmox/raw/main/apps/installers"
LLAMA_RELEASES="https://github.com/ggml-org/llama.cpp/releases"
HERMES_CT=120                           # Hermes LXC on the Proxmox host (for the printed commands)

# The service runs as the user who called sudo (uid 1000 owns the share), else root.
SVC_USER="${SUDO_USER:-root}"
id "$SVC_USER" &>/dev/null || SVC_USER="root"

# --- Environment checks ------------------------------------------------------
is_proxmox_host() { [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null; }
is_container()    { systemd-detect-virt -c &>/dev/null; }
has_cmd()         { command -v "$1" &>/dev/null; }

require_root() { [[ $EUID -eq 0 ]] || fail "Run with sudo: sudo bash -c \"\$(wget -qLO- ${GITHUB_BASE}/llama-setup.sh)\""; }

require_gpu_vm() {
    if is_proxmox_host; then
        echo ""
        warn "This runs inside the GPU VM (VM 200), not on the Proxmox host."
        echo "  On the host: pct list / qm list to find it, then SSH into the VM and run the same one-liner."
        exit 1
    fi
    if is_container; then
        echo ""
        warn "This runs inside the GPU VM, not in a container. The Hermes LXC has no GPU."
        exit 1
    fi
    has_cmd apt-get || fail "This script needs Ubuntu or Debian (apt-get not found)."
    if ! lspci 2>/dev/null | grep -qi nvidia; then
        echo ""
        warn "No NVIDIA GPU is visible in this VM."
        echo "  On the Proxmox host, pass the GPU through first:  gpu-setup bind <VMID>"
        echo "  then start the VM again and re-run this."
        exit 1
    fi
}

usage() {
    cat <<EOF
  Usage: llama-setup [command]  (run inside the GPU VM with sudo)
    (no args)         menu
    install [-y]      install or repair everything, then test
    status            service, GPU memory, speed, Hermes connection details
    test              one tool-calling request + speed measurement
    update            newest llama.cpp release
    thinking on|off   smarter (on) or faster (off) replies
    new-key           replace the API key (then update Hermes)
    retune            redo the GPU/RAM split search
    uninstall         remove server and settings (asks about the model file)
EOF
}

# Everything here touches /etc, systemd or apt, so root is needed throughout.
[[ "${1:-}" =~ ^(-h|--help)$ ]] || require_root

# Fetch and run a standalone installer from the repo (same pattern as vm-setup.sh).
run_remote() {
    local script="$1"; shift
    local body
    body="$(wget -qLO- "${GITHUB_BASE}/${script}?$(date +%s)")" || fail "Could not download ${script}. Is the VM online?"
    [[ -n "$body" ]] || fail "Downloaded ${script} but it was empty."
    bash -c "$body" "$script" "$@"
}

load_env() {
    [[ -f "$ENV_FILE" ]] || return 1
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
}

# Write or replace one KEY='value' line in the env file (mode 600, root). Values are
# single-quoted so both bash (load_env) and systemd (EnvironmentFile) read them alike.
set_env() {
    mkdir -p "$CONF_DIR"
    touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
    sed -i "/^$1=/d" "$ENV_FILE"
    printf "%s='%s'\n" "$1" "$2" >> "$ENV_FILE"
    backup_env
}

# Settings live on the VM (/etc) but a copy is kept on the host drive so a rebuilt VM
# gets the same API key and tuning back. Anyone with access to the 'sec' share can read
# that copy, so keep the share private.
STATE_DIR="${MOUNT_POINT}/apps/llama"
backup_env() {
    mountpoint -q "$MOUNT_POINT" 2>/dev/null || return 0
    mkdir -p "$STATE_DIR" && cp -f "$ENV_FILE" "$STATE_DIR/env" && chmod 600 "$STATE_DIR/env" || true
}
restore_env() {
    [[ -f "$ENV_FILE" ]] && return 0
    [[ -f "$STATE_DIR/env" ]] || return 0
    mkdir -p "$CONF_DIR"; cp -f "$STATE_DIR/env" "$ENV_FILE"; chmod 600 "$ENV_FILE"
    ok "Restored saved settings and API key from ${STATE_DIR} (Hermes keeps working)."
}
unset_env() { [[ -f "$ENV_FILE" ]] && sed -i "/^$1=/d" "$ENV_FILE"; backup_env; }
get_env() { { grep -s "^$1=" "$ENV_FILE" || true; } | cut -d= -f2- | tr -d "'"; }

is_installed() { [[ -f "$UNIT_FILE" && -f "$ENV_FILE" ]]; }
svc_state()    { [[ -f "$UNIT_FILE" ]] || { echo "not installed"; return; }; systemctl is-active "$SERVICE" 2>/dev/null || true; }
lan_ip()       { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}' || true; }

# Arguments shared by the tuner and the service. $1 = n-cpu-moe, $2 = host, $3 = port.
server_args() {
    local n="$1" host="$2" port="$3"
    printf '%s ' -m "$MODEL_PATH" --alias "$MODEL_ALIAS" -c "$CTX" --parallel 1 -ngl 999 --n-cpu-moe "$n" \
         -fa on --cache-type-k q8_0 --cache-type-v q8_0 --jinja --reasoning-format auto \
         --temp 0.6 --top-p 0.95 --top-k 20 --min-p 0.0 \
         --host "$host" --port "$port"
}
thinking_args() { [[ "${THINKING}" == "off" ]] && echo '--chat-template-kwargs {"enable_thinking":false}' || true; }
# The service gets the same setting through llama-server's own environment variable,
# because systemd strips quotes from expanded $VARS in ExecStart (JSON would break).
apply_thinking_env() {
    unset_env THINK_ARGS
    if [[ "${THINKING}" == "off" ]]; then set_env LLAMA_ARG_CHAT_TEMPLATE_KWARGS '{"enable_thinking":false}'
    else unset_env LLAMA_ARG_CHAT_TEMPLATE_KWARGS; fi
}

# --- Step 1: NVIDIA driver ---------------------------------------------------
step_driver() {
    if has_cmd nvidia-smi && nvidia-smi &>/dev/null; then
        ok "GPU: $(nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader | head -1)"
        return 0
    fi
    info "Installing the NVIDIA driver (gpu-setup.sh)..."
    local rc=0
    run_remote gpu-setup.sh driver -y || rc=$?
    if [[ $rc -eq 10 ]]; then
        echo ""
        hr
        echo "  The driver is installed but needs one reboot to start working."
        echo "  After the VM is back, log in and run this same command again."
        echo "  It carries on from here; nothing is repeated."
        hr
        if ask_yn "Reboot now?" y; then systemctl reboot; fi
        exit 0
    fi
    [[ $rc -eq 0 ]] || fail "Driver install did not finish. Run 'gpu-setup driver' by itself to see why."
    nvidia-smi &>/dev/null || fail "Driver installed but nvidia-smi still fails. Reboot the VM and re-run."
}

# --- Step 2: model storage ---------------------------------------------------
step_storage() {
    if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        info "Mounting the '${VIRTIOFS_TAG}' share at ${MOUNT_POINT} (virtiofs-setup.sh)..."
        run_remote virtiofs-setup.sh mount || true
    fi
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        MODEL_DIR="${MOUNT_POINT}/models/${MODEL_ALIAS}"
        ok "Model storage: ${MODEL_DIR} (host drive, survives a VM rebuild)"
    else
        MODEL_DIR="${APP_DIR}/models/${MODEL_ALIAS}"
        warn "The '${VIRTIOFS_TAG}' share is not available; the model would go on this VM's own disk."
        echo "  To use the host's big drive instead, run on the Proxmox host:  virtiofs-setup setup"
        ask_yn "Continue with the VM disk (${MODEL_DIR})?" n || fail "Stopped. Fix the share, then re-run."
    fi
    mkdir -p "$MODEL_DIR"
    local free_gb
    free_gb=$(df -BG --output=avail "$MODEL_DIR" | tail -n1 | tr -dc '0-9')
    if [[ ! -s "${MODEL_DIR}/${MODEL_FILE_NAME}" ]]; then
        (( free_gb >= MIN_FREE_GB )) || fail "Only ${free_gb} GB free at ${MODEL_DIR}; the model needs about ${MIN_FREE_GB} GB."
    fi
    MODEL_PATH="${MODEL_DIR}/${MODEL_FILE_NAME}"
}

# --- Step 3: llama.cpp -------------------------------------------------------
# llama.cpp publishes binaries on numbered builds (b12032). The "latest" release may be
# a version tag (v0.8.0) holding only nightly-tag.txt, which names the recommended build.
latest_tag() {
    local tag
    tag="$(curl -fsSL --max-time 20 https://api.github.com/repos/ggml-org/llama.cpp/releases/latest \
        | jq -r '.tag_name // empty')"
    if [[ -n "$tag" && ! "$tag" =~ ^b[0-9]+$ ]]; then
        tag="$(curl -fsSL --max-time 20 "${LLAMA_RELEASES}/download/${tag}/nightly-tag.txt" | tr -dc 'b0-9')"
    fi
    if [[ ! "$tag" =~ ^b[0-9]+$ ]]; then
        tag="$(curl -fsSL --max-time 20 "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=10" \
            | jq -r '[.[] | select(.tag_name | test("^b[0-9]+$")) | select(.assets | length > 1)][0].tag_name // empty')"
    fi
    [[ "$tag" =~ ^b[0-9]+$ ]] && echo "$tag"
    return 0
}

# Pick the prebuilt CUDA build the installed driver can run (CUDA 13 needs driver >= 580, CUDA 12.8 >= 570).
cuda_label() {
    local drv
    drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | cut -d. -f1)
    if   (( drv >= 580 )); then echo "13.4"
    elif (( drv >= 570 )); then echo "12.8"
    else echo ""; fi
}

# Download a release tarball pair into $APP_DIR/releases/<tag>. Returns 1 if not available.
fetch_prebuilt() {
    local tag="$1" label="$2" dest="$APP_DIR/releases/$1" tmp
    local base="${LLAMA_RELEASES}/download/${tag}"
    tmp="$(mktemp -d)"
    info "Downloading llama.cpp ${tag} (CUDA ${label}, prebuilt)..."
    if ! curl -fsSL --retry 3 -o "$tmp/llama.tar.gz"  "${base}/llama-${tag}-bin-ubuntu-cuda-${label}-x64.tar.gz" \
    || ! curl -fsSL --retry 3 -o "$tmp/cudart.tar.gz" "${base}/cudart-llama-${tag}-bin-ubuntu-cuda-${label}-x64.tar.gz"; then
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$dest"; mkdir -p "$dest"
    tar -xzf "$tmp/llama.tar.gz"  -C "$dest"
    local bin bindir
    bin="$(find "$dest" -type f -name llama-server | head -1)"
    [[ -n "$bin" ]] || { rm -rf "$tmp" "$dest"; return 1; }
    bindir="$(dirname "$bin")"
    tar -xzf "$tmp/cudart.tar.gz" -C "$bindir"
    # The binary loads its backends and the CUDA runtime from its own folder.
    find "$bindir" -mindepth 2 -name '*.so*' -exec mv -t "$bindir" {} + 2>/dev/null || true
    chmod +x "$bindir"/llama-* 2>/dev/null || true
    rm -rf "$tmp"
    ln -sfn "$bindir" "$APP_DIR/current"
}

build_from_source() {
    local src="$APP_DIR/src"
    warn "No prebuilt CUDA build matches this driver; building from source (10-20 minutes)."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq build-essential cmake git libcurl4-openssl-dev nvidia-cuda-toolkit >/dev/null 2>&1 \
        || fail "Could not install the build tools or CUDA toolkit."
    if [[ -d "$src/.git" ]]; then git -C "$src" pull -q --ff-only || true
    else git clone -q --depth 1 https://github.com/ggml-org/llama.cpp "$src"; fi
    cmake -S "$src" -B "$src/build" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release >/dev/null \
        || fail "CUDA build setup failed. The CUDA toolkit in apt may not match this driver yet; try again after 'apt upgrade'."
    cmake --build "$src/build" --config Release -j"$(nproc)" --target llama-server >/dev/null \
        || fail "Build failed. See the output above."
    ln -sfn "$src/build/bin" "$APP_DIR/current"
}

# Confirms the active binary runs and actually sees the GPU.
verify_binary() {
    local bin="$APP_DIR/current/llama-server"
    [[ -x "$bin" ]] || return 1
    LD_LIBRARY_PATH="$APP_DIR/current" "$bin" --list-devices 2>&1 | grep -qi cuda
}

step_llama() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y -qq curl jq ca-certificates pciutils >/dev/null 2>&1 || true
    mkdir -p "$APP_DIR/releases"
    local want="${1:-}" tag label
    if [[ -z "$want" ]] && verify_binary; then
        ok "llama.cpp present: $(readlink -f "$APP_DIR/current" | grep -oE 'b[0-9]+' | head -1 || echo 'source build')"
        return 0
    fi
    tag="${want:-$(latest_tag)}"
    [[ -n "$tag" ]] || fail "Could not look up the latest llama.cpp release. Is GitHub reachable from the VM?"
    label="$(cuda_label)"
    local done_prebuilt=0
    if [[ -n "$label" ]]; then
        fetch_prebuilt "$tag" "$label" && done_prebuilt=1
        # Fall back to the other CUDA generation if the asset for this one is missing.
        if [[ $done_prebuilt -eq 0 && "$label" == "13.4" ]]; then fetch_prebuilt "$tag" "12.8" && done_prebuilt=1; fi
    fi
    if [[ $done_prebuilt -eq 1 ]] && verify_binary; then
        ok "llama.cpp ${tag} installed (prebuilt CUDA ${label})."
    else
        build_from_source
        verify_binary || fail "llama-server built but does not see the GPU. Check 'nvidia-smi' and reboot once."
        ok "llama.cpp built from source."
    fi
    # Keep only the two newest prebuilt releases.
    ls -1dt "$APP_DIR"/releases/*/ 2>/dev/null | tail -n +3 | xargs -r rm -rf
}

# --- Step 4: model download --------------------------------------------------
hf_file_size() { # size in bytes as published by Hugging Face, empty if unknown
    curl -fsSL --max-time 30 "https://huggingface.co/api/models/${HF_REPO}/tree/main" \
        | jq -r --arg f "$MODEL_FILE_NAME" '.[] | select(.path==$f) | (.lfs.size // .size) // empty' 2>/dev/null | head -1
}

step_model() {
    local url="https://huggingface.co/${HF_REPO}/resolve/main/${MODEL_FILE_NAME}" want have
    want="$(hf_file_size || true)"
    have=$(stat -c %s "$MODEL_PATH" 2>/dev/null || echo 0)
    if [[ -n "$want" && "$have" == "$want" ]]; then
        ok "Model present: ${MODEL_FILE_NAME} ($(( have / 1024 / 1024 / 1024 )) GB)"
        return 0
    fi
    if [[ -z "$want" ]]; then
        warn "Could not confirm the file size with Hugging Face (offline or API busy)."
        if (( have > 0 )); then warn "A model file already exists; assuming it is complete."; return 0; fi
    fi
    info "Downloading ${MODEL_FILE_NAME} (about $(( ${want:-22000000000} / 1000000000 )) GB). Resumes if interrupted."
    # -C - resumes a partial file; --retry survives flaky connections. No token needed (public repo).
    curl -L --fail --retry 10 --retry-all-errors --retry-delay 5 -C - --progress-bar \
        -o "$MODEL_PATH" "$url" || fail "Download failed. Re-run this step; it continues where it stopped."
    have=$(stat -c %s "$MODEL_PATH")
    if [[ -n "$want" && "$have" != "$want" ]]; then
        rm -f "$MODEL_PATH"
        fail "Downloaded file size does not match Hugging Face. The file was removed; re-run to download again."
    fi
    chmod 644 "$MODEL_PATH"
    ok "Model downloaded and verified."
}

# --- Step 5: GPU/RAM split ---------------------------------------------------
# --n-cpu-moe N keeps the expert weights of the first N layers in RAM. Lower N = more
# on the GPU = faster. We try from 0 upward and keep the first value that loads with
# the full context. Results are stored so re-runs skip this (menu "install" with a new
# quant or 'retune' clears them).
wait_health() { # wait_health port pid timeout_s  -> 0 ready, 1 died/timeout
    local port="$1" pid="$2" t="$3" i
    for ((i=0; i<t; i+=2)); do
        kill -0 "$pid" 2>/dev/null || return 1
        curl -sf --max-time 2 "http://127.0.0.1:${port}/health" >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

measure_tps() { # measure_tps port [api-key] -> integer tokens/sec (0 if unknown)
    local hdr=()
    [[ -n "${2:-}" ]] && hdr=(-H "Authorization: Bearer $2")
    local t
    t=$(curl -s --max-time 120 "${hdr[@]}" "http://127.0.0.1:$1/completion" \
        -d '{"prompt":"Write a short paragraph about Singapore.","n_predict":128,"temperature":0.6}' \
        | jq -r '.timings.predicted_per_second // 0' 2>/dev/null | cut -d. -f1 || true)
    echo "${t:-0}"
}

# Start a trial server with split $1, wait for it, measure, stop it. Prints tokens/sec or "" if it did not fit.
try_split() {
    local n="$1" pid tps
    echo "=== --n-cpu-moe $n ===" >> "$TUNE_LOG"
    # shellcheck disable=SC2046
    LD_LIBRARY_PATH="$APP_DIR/current" "$APP_DIR/current/llama-server" \
        $(server_args "$n" 127.0.0.1 "$TEST_PORT") $(thinking_args) >>"$TUNE_LOG" 2>&1 &
    pid=$!
    if wait_health "$TEST_PORT" "$pid" 400; then
        tps="$(measure_tps "$TEST_PORT")"
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        echo "$tps"
    else
        kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
        echo ""
    fi
}

step_tune() {
    local prev_n prev_for prev_tps
    prev_n="$(get_env N_CPU_MOE)"; prev_for="$(get_env TUNED_FOR)"; prev_tps="$(get_env TOKENS_PER_SEC)"
    if [[ -n "$prev_n" && "$prev_for" == "${MODEL_FILE_NAME}:${CTX}" ]]; then
        ok "GPU/RAM split already tuned: --n-cpu-moe ${prev_n} (~${prev_tps:-?} tokens/sec)"
        return 0
    fi
    systemctl stop "$SERVICE" 2>/dev/null || true
    info "Finding the fastest GPU/RAM split that fits (each try loads the model; 5-15 minutes in total)..."
    : > "$TUNE_LOG"
    local n tps best_n="" best_tps=0 extra=0
    # First value that fits is usually fastest; two more tries guard against a
    # "fits but slow" result when llama.cpp quietly moved layers off the GPU.
    for n in 0 4 8 12 16 20 24 28 32 40 48; do
        printf '  trying --n-cpu-moe %-3s ... ' "$n"
        tps="$(try_split "$n")"
        if [[ -z "$tps" ]]; then echo "does not fit"; continue; fi
        echo "fits, ~${tps} tokens/sec"
        if (( tps > best_tps )); then best_n="$n"; best_tps="$tps"; fi
        extra=$((extra + 1)); (( extra >= 3 )) && break
    done
    [[ -n "$best_n" ]] || fail "The model does not fit at any split. Try the smaller model: LLM_QUANT=UD-Q3_K_XL ... install. Details: ${TUNE_LOG}"
    set_env N_CPU_MOE "$best_n"
    set_env TOKENS_PER_SEC "$best_tps"
    set_env TUNED_FOR "${MODEL_FILE_NAME}:${CTX}"
    if (( best_tps > 0 && best_tps < 15 )); then
        warn "About ${best_tps} tokens/sec is on the slow side for an agent."
        echo "  Options: 'thinking off' (big speed-up) or the smaller model LLM_QUANT=UD-Q3_K_XL (slightly less accurate)."
    fi
    ok "Chosen: --n-cpu-moe ${best_n} (~${best_tps} tokens/sec)"
}

# --- Step 6: service ---------------------------------------------------------
write_service() {
    local key
    if ! grep -q '^LLAMA_API_KEY=' "$ENV_FILE" 2>/dev/null; then
        key="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
        set_env LLAMA_API_KEY "$key"
    fi
    set_env MODEL_PATH "$MODEL_PATH"
    set_env MODEL_ALIAS "$MODEL_ALIAS"
    set_env CTX "$CTX"
    set_env PORT "$PORT"
    set_env THINKING "$THINKING"
    set_env LAN_IP "$(lan_ip)"
    apply_thinking_env
    load_env
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=Local LLM server (llama.cpp, ${MODEL_ALIAS}) for Hermes
After=network-online.target remote-fs.target
Wants=network-online.target
RequiresMountsFor=$(dirname "$MODEL_PATH")

[Service]
User=${SVC_USER}
EnvironmentFile=${ENV_FILE}
Environment=LD_LIBRARY_PATH=${APP_DIR}/current
ExecStart=${APP_DIR}/current/llama-server $(server_args '${N_CPU_MOE}' 0.0.0.0 '${PORT}')
Restart=on-failure
RestartSec=5
# llama-server reads the key from LLAMA_API_KEY in the env file.

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$SERVICE" >/dev/null 2>&1
    echo -n "  Starting the server"
    local i
    for i in $(seq 1 200); do
        curl -sf --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && break
        systemctl is-active --quiet "$SERVICE" || break
        echo -n "."; sleep 2
    done
    echo
    curl -sf --max-time 2 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 \
        || fail "The server did not start. Recent log:
$(journalctl -u "$SERVICE" --no-pager -n 15 | sed 's/^/    /')"
    ok "Service '${SERVICE}' is running on port ${PORT}."
}

# --- Step 7: test ------------------------------------------------------------
run_test() {
    load_env || fail "Not installed yet."
    local base="http://127.0.0.1:${PORT}" props nctx resp tool tps
    curl -sf --max-time 3 "$base/health" >/dev/null || fail "Server not responding. Run: llama-setup status"

    props="$(curl -s --max-time 5 "$base/props" -H "Authorization: Bearer ${LLAMA_API_KEY}" || true)"
    nctx="$(echo "$props" | jq -r '.default_generation_settings.n_ctx // 0' 2>/dev/null || echo 0)"
    if (( nctx >= 64000 )); then ok "Context: ${nctx} tokens (Hermes needs 64,000+)."
    else warn "Context is ${nctx}; Hermes needs 64,000+. Re-run install."; fi

    info "Sending one tool-calling request..."
    resp=$(curl -s --max-time 180 "$base/v1/chat/completions" \
        -H "Authorization: Bearer ${LLAMA_API_KEY}" -H "Content-Type: application/json" \
        -d '{"model":"'"${MODEL_ALIAS}"'",
             "messages":[{"role":"user","content":"What is the weather in Singapore right now? Use the tool."}],
             "tools":[{"type":"function","function":{"name":"get_weather","description":"Get current weather for a city",
               "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]}' || true)
    tool="$(echo "$resp" | jq -c '.choices[0].message.tool_calls[0].function // empty' 2>/dev/null || true)"
    if [[ -n "$tool" ]]; then ok "Tool call works: ${tool}"
    else warn "No tool call came back. Raw reply:"; echo "$resp" | jq . 2>/dev/null | head -30 | sed 's/^/    /' || echo "$resp"; fi

    tps="$(measure_tps "$PORT" "$LLAMA_API_KEY")"
    [[ "$tps" != "0" ]] && { set_env TOKENS_PER_SEC "$tps"; ok "Speed: ~${tps} tokens/sec"; }
    echo "  GPU now: $(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null | head -1)"
}

# --- Hermes connection details -----------------------------------------------
print_connect() {
    load_env || return 0
    local ip; ip="$(lan_ip)"
    echo ""
    hr
    echo "  Connect Hermes"
    hr
    echo "  On the Proxmox host:"
    echo "    - hermes-setup.sh  >  8) Use local LLM"
    echo ""
    echo "  Other clients:"
    echo "    - URL      http://${ip:-<VM-IP>}:${PORT}/v1"
    echo "    - Model    ${MODEL_ALIAS}   context ${CTX}"
    echo "    - API key  ${LLAMA_API_KEY}"
    echo ""
}

# --- Actions -----------------------------------------------------------------
action_install() {
    require_root; require_gpu_vm
    echo ""
    echo "Install / Repair"
    hr
    echo ""
    info "Step 1/7  NVIDIA driver";        step_driver
    info "Step 2/7  Model storage";        step_storage; restore_env
    info "Step 3/7  llama.cpp";            step_llama
    info "Step 4/7  Model download";       step_model
    info "Step 5/7  GPU/RAM split";        step_tune
    info "Step 6/7  Service";              write_service
    info "Step 7/7  Test";                 run_test
    echo ""
    hr
    echo "  Done. The model runs as a service and starts with the VM."
    hr
    action_status_brief
    print_connect
}

action_status_brief() {
    load_env || return 0
    echo ""
    echo "  Service  : ${SERVICE}  [$(svc_state)]"
    echo "  Model    : ${MODEL_PATH:-?}"
    echo "  Split    : --n-cpu-moe ${N_CPU_MOE:-?}   Speed: ~${TOKENS_PER_SEC:-?} tokens/sec   Thinking: ${THINKING:-off}"
    echo "  GPU      : $(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo unknown)"
    echo "  Address  : http://$(lan_ip):${PORT:-8080}/v1"
}

action_status() {
    is_installed || { info "Local LLM is not installed. Choose 'Install' first."; return; }
    load_env
    action_status_brief
    echo -n "  Health   : "
    curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" 2>/dev/null || echo "(no response)"
    echo ""
    echo ""
    echo "  Recent log:"
    journalctl -u "$SERVICE" --no-pager -n 8 2>/dev/null | sed 's/^/    /' || true
    print_connect
}

action_update() {
    require_root; is_installed || fail "Not installed yet."
    load_env
    local tag; tag="$(latest_tag)"
    [[ -n "$tag" ]] || fail "Could not look up the latest release."
    if readlink -f "$APP_DIR/current" | grep -q "/releases/${tag}/"; then
        ok "Already on llama.cpp ${tag}."; return
    fi
    step_llama "$tag"
    systemctl restart "$SERVICE"
    sleep 5; run_test
}

action_thinking() {
    require_root; is_installed || fail "Not installed yet."
    case "${1:-}" in
        on|off) THINKING="$1" ;;
        *) fail "Use: thinking on   (smarter, slower)   or   thinking off   (faster)" ;;
    esac
    set_env THINKING "$THINKING"
    apply_thinking_env
    systemctl restart "$SERVICE"
    ok "Thinking ${THINKING}. Server restarting (about a minute)."
}

action_uninstall() {
    require_root; is_installed || { info "Nothing to remove."; return; }
    load_env
    echo ""
    echo "  This stops and removes the LLM server, its settings and API key."
    ask_yn "Remove the server?" n || { info "Cancelled."; return; }
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f "$UNIT_FILE"; systemctl daemon-reload
    rm -rf "$CONF_DIR" "$APP_DIR/releases" "$APP_DIR/src" "$APP_DIR/current"
    ok "Server removed."
    if [[ -f "$STATE_DIR/env" ]]; then
        echo ""
        echo "  A copy of the settings and API key is kept on the host drive: ${STATE_DIR}"
        echo "  Keep it and a reinstall reconnects to Hermes with no changes needed."
        if ask_yn "Delete that saved copy too?" n; then rm -rf "$STATE_DIR"; ok "Saved settings deleted."; fi
    fi
    if [[ -n "${MODEL_PATH:-}" && -f "$MODEL_PATH" ]]; then
        echo ""
        echo "  The model file is still on disk ($(du -h "$MODEL_PATH" | cut -f1)): ${MODEL_PATH}"
        echo "  Keep it if you may reinstall later (saves the 22 GB download)."
        if ask_yn "Delete the model file too?" n; then rm -rf "$(dirname "$MODEL_PATH")"; ok "Model deleted."; fi
    fi
    rmdir "$APP_DIR" 2>/dev/null || true
    echo ""
    echo "  Hermes: point it back at Claude with menu option 3 of hermes-setup.sh on the Proxmox host."
}

# Replace the API key. The server restarts with the new key; Hermes keeps the old
# one until the printed command is run on the Proxmox host, so it is shown here.
action_new_key() {
    load_env || fail "Not installed yet."
    echo "  The old key stops working immediately. Hermes will be offline until you"
    echo "  run the two commands printed below on the Proxmox host."
    ask_yn "Generate a new API key?" n || { info "Cancelled."; return; }
    local key; key="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
    set_env LLAMA_API_KEY "$key"
    systemctl restart "$SERVICE"
    ok "New API key set. Server restarting (about a minute)."
    echo ""
    echo "  Now give Hermes the new key (copy-paste on the Proxmox host shell):"
    echo ""
    echo "  CT=${HERMES_CT}; HU=\$(pct exec \$CT -- stat -c %u /opt/hermes/data)"
    echo "  pct exec \$CT -- docker exec -u \$HU hermes hermes config set LLAMA_API_KEY ${key}"
    echo "  pct exec \$CT -- docker restart hermes"
    echo ""
}

# --- Settings menu -----------------------------------------------------------
settings_menu() {
    load_env || fail "Not installed yet. Choose 'Install' first."
    echo ""
    echo "  Settings"
    echo "  ----------------------------------------------------------------"
    echo "  Thinking mode is currently: ${THINKING:-off}"
    echo ""
    echo "  1) Thinking mode on   (smarter, slower replies)"
    echo "  2) Thinking mode off  (faster replies, recommended)"
    echo "  3) New API key        (use if the old key may have leaked)"
    echo "  b) Back"
    echo ""
    local c
    read -rp "Select an option: " c </dev/tty
    echo ""
    case "$c" in
        1) action_thinking on ;;
        2) action_thinking off ;;
        3) action_new_key ;;
        b|B) menu ;;
        *) fail "Invalid option." ;;
    esac
}

# --- Menu --------------------------------------------------------------------
menu() {
    echo ""
    hr
    echo "  Local LLM for Hermes - GPU VM Installer"
    hr
    echo ""
    if is_installed; then
        ok "Installed  [$(svc_state)]"
    else
        info "Not installed"
        echo ""
        echo "  Runs a free open model (Qwen3.6-35B-A3B) on this VM's GPU so Hermes can do"
        echo "  routine work without using Claude credits. Takes 20-40 minutes the first"
        echo "  time (22 GB download). Everything else is automatic."
    fi
    echo ""
    echo "  1) Install or repair"
    echo "  2) Status"
    echo "  3) Test (tool call + speed)"
    echo "  4) Settings"
    echo "  5) Update llama.cpp"
    echo "  6) Uninstall"
    echo "  0) Exit"
    echo ""
    local choice
    read -rp "Select an option: " choice </dev/tty
    echo ""
    case "$choice" in
        1) action_install ;;
        2) action_status ;;
        3) run_test ;;
        4) settings_menu ;;
        5) action_update ;;
        6) action_uninstall ;;
        0) exit 0 ;;
        *) fail "Invalid option." ;;
    esac
}

# --- Dispatch ----------------------------------------------------------------
ARGS=()
for a in "$@"; do
    case "$a" in -y|--yes) YES=1 ;; *) ARGS+=("$a") ;; esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "${1:-}" in
    "")         menu ;;
    install)    action_install ;;
    status)     action_status ;;
    test)       run_test ;;
    update)     action_update ;;
    thinking)   action_thinking "${2:-}" ;;
    new-key)    action_new_key ;;
    retune)     load_env || fail "Not installed yet."
                set_env TUNED_FOR ""; step_tune; write_service; run_test ;;
    uninstall)  action_uninstall ;;
    -h|--help)  usage ;;
    *)          echo ""; usage; fail "Unknown command '${1}'." ;;
esac
