#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/report-llmfit.sh?$(date +%s))"
# Purpose: Recommend local LLMs that fit this machine's GPU/RAM via llmfit (VM/LXC, no sudo)
# =============================================================================
# Usage:
#   report-llmfit.sh                  menu (with no terminal: same as fit)
#   report-llmfit.sh fit              ranked table of models that fit
#   report-llmfit.sh agent            only models with tool-use support (Hermes)
#   report-llmfit.sh perfect          only models that fit fully in VRAM
#   report-llmfit.sh uncensored       only abliterated / uncensored models
#   report-llmfit.sh system           detected GPU / VRAM / RAM
#   report-llmfit.sh uninstall        remove llmfit (add --all to remove uv too)
#   report-llmfit.sh <other>          passed straight through to llmfit
# =============================================================================

set -euo pipefail

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

SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/report-llmfit.sh"

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

LIMIT="${LIMIT:-8}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
UV_BIN="$HOME/.local/bin"

# --- uv bootstrap ------------------------------------------------------------
ensure_uv() {
    command -v uv &>/dev/null && return 0
    command -v curl &>/dev/null || fail "curl is required to install uv (apt install curl)"
    info "Installing uv to ~/.local/bin (user-level, no sudo)"
    # UV_NO_MODIFY_PATH: keep shell rc files untouched; this script sets PATH itself
    curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 sh >/dev/null
    command -v uv &>/dev/null || fail "uv install finished but 'uv' is not on PATH — open a new shell and retry"
    ok "uv installed: $(uv --version | head -1)"
}

# Other processes holding VRAM (e.g. llama-server) leave less room than llmfit's table assumes.
gpu_note() {
    command -v nvidia-smi &>/dev/null || { warn "nvidia-smi not found — llmfit will size against CPU/RAM only"; return 0; }
    local apps
    apps=$(nvidia-smi --query-compute-apps=process_name,used_memory --format=csv,noheader,nounits 2>/dev/null \
        | awk -F', *' '$2 > 1024 { n=$1; sub(".*/", "", n); printf "%s%s %.1f GiB", sep, n, $2/1024; sep=", " }' || true)
    [[ -n "$apps" ]] && warn "VRAM in use by: ${apps}. Stop it to load a model listed here."
    return 0
}

run_llmfit() {
    ensure_uv
    gpu_note
    info "uvx llmfit $*"
    uvx llmfit "$@"
}

llmfit_cached() {
    command -v uv &>/dev/null || return 1
    local d; d=$(uv cache dir 2>/dev/null || true)
    [[ -n "$d" ]] && compgen -G "$d/archive-v0/*/llmfit*" >/dev/null 2>&1
}

# --- Commands ----------------------------------------------------------------
cmd_fit()     { run_llmfit fit -n "$LIMIT" "$@"; }
cmd_agent()   { run_llmfit fit --tool-use -n "$LIMIT" "$@"; }
cmd_perfect() { run_llmfit fit --perfect -n "$LIMIT" "$@"; }

# llmfit has no uncensored filter: rank everything, keep matching names, cut to LIMIT.
cmd_uncensored() {
    ensure_uv
    gpu_note
    info "uvx llmfit fit -n 5000 (names matching abliterated / heretic / uncensored)"
    uvx llmfit fit -n 5000 "$@" | awk -v lim="$LIMIT" '
        !body { if ($0 ~ /^Found [0-9]+ compatible/) next; print; if ($0 ~ /^├/) body=1; next }
        /^╰/  { if (!n) print "│ (none fit this machine)"; print; body=2; next }
        body == 1 { if (n < lim && tolower($0) ~ /abliterat|heretic|uncensor/) { print; n++ } next }
        { print }'
}

remove_uv() {
    local f
    rm -rf "$HOME/.cache/uv" "$HOME/.local/share/uv"
    rm -f "$UV_BIN/uv" "$UV_BIN/uvx" "$UV_BIN/env" "$UV_BIN/env.fish"
    # Older runs let the uv installer add this line to shell startup files.
    for f in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.zshenv"; do
        # shellcheck disable=SC2016  # literal line written by the uv installer
        [[ -f "$f" ]] && sed -i '\#^\. "\$HOME/\.local/bin/env"$#d' "$f"
    done
    ok "Removed uv, uvx and their cache"
}

cmd_uninstall() {
    if command -v uv &>/dev/null; then
        uv cache clean llmfit >/dev/null 2>&1 || true
    fi
    ok "Removed llmfit"
    shortcut_on && { shortcut_toggle; }
    if [[ "${1:-}" == "--all" ]]; then
        remove_uv
    else
        info "uv left in ~/.local/bin (other tools may use it). To remove it too:"
        echo "       choose Uninstall in the menu, or run with 'uninstall --all'"
    fi
}

uninstall_menu() {
    local c=""
    read -rp "  Remove llmfit from this machine? [y/N]: " c </dev/tty || c=""
    [[ "$c" =~ ^[Yy]$ ]] || { info "Nothing removed."; return 0; }
    if command -v uv &>/dev/null; then
        read -rp "  Also remove uv (skip if you use uv for anything else)? [y/N]: " c </dev/tty || c=""
        if [[ "$c" =~ ^[Yy]$ ]]; then cmd_uninstall --all; return 0; fi
    fi
    cmd_uninstall
    return 0
}

# --- Menus -------------------------------------------------------------------
settings_menu() {
    local n=""
    while true; do
        banner "LLMfit > Settings"
        info "Models listed per table: $LIMIT"
        menu "Count|models listed per table [$LIMIT]" \
             "Shortcut|[$(shortcut_state)]  type '$(shortcut_name)' in a new shell" "Back"
        case "$CHOICE" in
            Count)
                read -rp "  Models to list [$LIMIT]: " n </dev/tty || n=""
                if [[ -z "$n" ]]; then :
                elif [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 200 )); then LIMIT="$n"; ok "Listing $LIMIT models."
                else warn "Enter a number from 1 to 200."; fi ;;
            Shortcut) shortcut_toggle ;;
            Back)     return 0 ;;
        esac
    done
}

main_menu() {
    local state
    while true; do
        banner "LLMfit"
        if llmfit_cached; then state="llmfit ready"; else state="llmfit not downloaded yet (first run takes a few seconds)"; fi
        info "$state  ·  listing $LIMIT models"
        menu "Fit|models that fit, ranked" \
             "Agent|tool-use models only (Hermes)" \
             "Perfect|models that fit fully in VRAM" \
             "Uncensored|abliterated / uncensored models only" \
             "System|detected GPU, VRAM and RAM" \
             "Settings" \
             "Uninstall|remove llmfit (and optionally uv)"
        case "$CHOICE" in
            Fit)        cmd_fit || warn "llmfit exited with an error." ;;
            Agent)      cmd_agent || warn "llmfit exited with an error." ;;
            Perfect)    cmd_perfect || warn "llmfit exited with an error." ;;
            Uncensored) cmd_uncensored || warn "llmfit exited with an error." ;;
            System)     run_llmfit system || warn "llmfit exited with an error." ;;
            Settings)   settings_menu ;;
            Uninstall)  uninstall_menu ;;
        esac
    done
}

# --- Main --------------------------------------------------------------------
case "${1:-}" in
    "")          if { true </dev/tty; } 2>/dev/null; then main_menu; else cmd_fit; fi ;;
    fit)         shift; cmd_fit "$@" ;;
    agent)       shift; cmd_agent "$@" ;;
    perfect)     shift; cmd_perfect "$@" ;;
    uncensored)  shift; cmd_uncensored "$@" ;;
    system)      shift; run_llmfit system "$@" ;;
    uninstall)   shift; cmd_uninstall "$@" ;;
    -h|--help)   sed -n '5,13p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//' || true; exit 0 ;;
    *)           run_llmfit "$@" ;;
esac
