#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/llmfit.sh?$(date +%s))"
# Purpose: Recommend local LLMs that fit this machine's GPU/RAM via llmfit (VM/LXC, no sudo)
# =============================================================================
# Usage:
#   llmfit.sh [command] [args...]
#   LIMIT=25 bash -c "$(wget -qLO- <raw-url>)" _ agent   # one-liner form: args go after _
#
#   (no args)        ranked table of models that fit (default LIMIT=8)
#   system           show detected GPU / VRAM / RAM
#   fit              same as no args (table)
#   perfect          table, only models that fit fully in VRAM
#   agent            table, only models with tool-use support (Hermes etc.)
#   recommend        same shortlist as JSON (llmfit's agent-oriented output)
#   uninstall        remove the uv cache (and uv itself with --all)
#   <anything else>  passed straight through to llmfit
#
# Environment:
#   LIMIT=8          number of models to list
#
# Nothing is installed system-wide: uv goes to ~/.local/bin and llmfit runs
# in a throwaway environment under ~/.cache/uv. System Python, Ollama and
# drivers are never touched. Re-running is safe.
# =============================================================================

set -euo pipefail

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

LIMIT="${LIMIT:-8}"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# --- uv bootstrap ------------------------------------------------------------
ensure_uv() {
    if command -v uv &>/dev/null; then
        ok "uv present: $(uv --version 2>/dev/null | head -1)"
        return
    fi
    command -v curl &>/dev/null || fail "curl is required to install uv (apt install curl)"
    info "Installing uv to ~/.local/bin (user-level, no sudo)"
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
    command -v uv &>/dev/null || fail "uv install finished but 'uv' is not on PATH — open a new shell and retry"
    ok "uv installed: $(uv --version | head -1)"
}

run_llmfit() {
    ensure_uv
    if ! command -v nvidia-smi &>/dev/null; then
        warn "nvidia-smi not found — llmfit will size against CPU/RAM only"
    fi
    info "uvx llmfit $*"
    uvx llmfit "$@"
}

# --- Commands ----------------------------------------------------------------
cmd_fit() {
    run_llmfit fit -n "$LIMIT" "$@"
    echo ""
    info "For agents (Hermes) filter to tool-use models: re-run with 'agent' as the argument (one-liner: ... _ agent)."
}

cmd_uninstall() {
    rm -rf "$HOME/.cache/uv"
    ok "Removed ~/.cache/uv (llmfit environment)"
    if [[ "${1:-}" == "--all" ]]; then
        rm -f "$HOME/.local/bin/uv" "$HOME/.local/bin/uvx"
        ok "Removed uv and uvx from ~/.local/bin"
    else
        info "uv left in ~/.local/bin — run 'llmfit.sh uninstall --all' to remove it too"
    fi
}

# --- Main --------------------------------------------------------------------
case "${1:-}" in
    "")          cmd_fit ;;
    system)      shift; run_llmfit system "$@" ;;
    fit)         shift; cmd_fit "$@" ;;
    perfect)     shift; cmd_fit --perfect "$@" ;;
    agent)       shift; run_llmfit fit --tool-use -n "$LIMIT" "$@" ;;
    recommend)   shift; run_llmfit recommend --limit "$LIMIT" "$@" ;;
    uninstall)   shift; cmd_uninstall "$@" ;;
    -h|--help)   sed -n '5,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           run_llmfit "$@" ;;
esac
