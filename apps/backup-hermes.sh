#!/usr/bin/env bash
# Installed by setup-hermes.sh, menu option "Back up to GitHub". Not run directly.
# Purpose: Nightly backup of Hermes skills, scripts, jobs, config and memories to a private GitHub repo (run inside the Hermes LXC)
# =============================================================================
# Usage (inside the Hermes LXC):
#   backup-hermes.sh --install   install git/rsync/cron, schedule 03:30 daily, run once
#   backup-hermes.sh             back up now (what the schedule runs)
#   backup-hermes.sh --restore   copy the latest backup back into Hermes (stop Hermes first)
#
# Needs a GitHub deploy key with write access at /root/.ssh/backup_hermes.
# Secrets (.env, auth.json, google_*.json), databases, logs and caches are never copied.
#
# Settings come from /etc/backup-hermes.conf (written by setup-hermes.sh) or the environment:
#   HERMES_BACKUP_REPO   git URL, e.g. git@github.com:owner/repo.git   (required)
#   HERMES_BACKUP_DIR    folder inside the repo                         (default backup/hermes)
#   HERMES_DATA          Hermes data folder                             (default /opt/hermes/data)
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

CONF=/etc/backup-hermes.conf
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

REPO_URL="${HERMES_BACKUP_REPO:-}"
DEST="${HERMES_BACKUP_DIR:-backup/hermes}"
SRC="${HERMES_DATA:-/opt/hermes/data}"
KEY=/root/.ssh/backup_hermes
WORK=/root/backup-hermes-repo
SELF=/usr/local/bin/backup-hermes.sh
CRON=/etc/cron.d/backup-hermes

# Tokens that must never reach the repo, even inside a skill or script.
SECRET_RE='sk-ant-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|"refresh_token": *"1//|-----BEGIN [A-Z ]*PRIVATE KEY-----'

do_install() {
    [[ $EUID -eq 0 ]] || fail "Run as root."
    [[ -f "$KEY" ]] || fail "Deploy key $KEY not found."
    info "Installing git, rsync and cron..."
    apt-get install -y git rsync cron >/dev/null 2>&1 || fail "apt-get install failed."
    [[ "$(realpath "$0")" == "$SELF" ]] || install -m 755 "$0" "$SELF"
    echo "30 3 * * * root $SELF >>/var/log/backup-hermes.log 2>&1" >"$CRON"
    chmod 644 "$CRON"
    ok "Scheduled daily at 03:30 (log: /var/log/backup-hermes.log)."
    backup
}

copy_dir() {  # copy_dir <src> <dest> [rsync excludes...]
    local src="$1" dest="$2"; shift 2
    [[ -d "$src" ]] || { warn "Skipped $src (missing)."; return; }
    mkdir -p "$dest"
    rsync -a --delete --exclude='__pycache__' --exclude='*.pyc' "$@" "$src/" "$dest/"
}

copy_file() {  # copy_file <src> <dest>
    [[ -f "$1" ]] && cp "$1" "$2" || warn "Skipped $1 (missing)."
}

fetch() {  # clone or update the backup folder into $WORK
    [[ -n "$REPO_URL" ]] || fail "No repo set. Configure it from setup-hermes.sh."
    export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

    # Start over if the repo was changed since the last run.
    if [[ -d "$WORK/.git" && "$(git -C "$WORK" config --get remote.origin.url)" != "$REPO_URL" ]]; then
        rm -rf "$WORK"
    fi
    if [[ ! -d "$WORK/.git" ]]; then
        info "Cloning $REPO_URL (only $DEST/)..."
        git clone -q --filter=blob:none --sparse "$REPO_URL" "$WORK"
        git -C "$WORK" config user.name "backup-hermes"
        git -C "$WORK" config user.email "backup-hermes@localhost"
    fi
    cd "$WORK"
    git sparse-checkout set "$DEST"
    git pull -q --rebase
}

backup() {
    fetch
    copy_dir "$SRC/skills"   "$DEST/skills" --exclude='.*'
    copy_dir "$SRC/scripts"  "$DEST/scripts"
    copy_dir "$SRC/memories" "$DEST/memories"
    copy_file "$SRC/config.yaml"    "$DEST/config.yaml"
    copy_file "$SRC/SOUL.md"        "$DEST/SOUL.md"
    copy_file "$SRC/cron/jobs.json" "$DEST/cron-jobs.json"

    if grep -rlE "$SECRET_RE" "$DEST" >&2; then
        fail "Possible secret in the files above. Nothing was pushed."
    fi

    git add -A "$DEST"
    if git diff --cached --quiet; then
        ok "No changes since last backup."
        return
    fi
    git commit -qm "hermes: backup $(date +%F)"
    git push -q
    ok "Backed up to $REPO_URL ($DEST/)."
}

restore() {
    fetch
    [[ -d "$DEST" ]] || fail "No backup found in $REPO_URL ($DEST/)."
    [[ -d "$SRC" ]] || fail "Hermes data folder $SRC not found."
    local owner; owner=$(stat -c %u:%g "$SRC")
    mkdir -p "$SRC/cron"
    copy_dir "$DEST/skills"   "$SRC/skills" --exclude='.*'
    copy_dir "$DEST/scripts"  "$SRC/scripts"
    copy_dir "$DEST/memories" "$SRC/memories"
    copy_file "$DEST/config.yaml"    "$SRC/config.yaml"
    copy_file "$DEST/SOUL.md"        "$SRC/SOUL.md"
    copy_file "$DEST/cron-jobs.json" "$SRC/cron/jobs.json"
    chown -R "$owner" "$SRC/skills" "$SRC/scripts" "$SRC/memories" "$SRC/cron" 2>/dev/null || true
    chown "$owner" "$SRC/config.yaml" "$SRC/SOUL.md" 2>/dev/null || true
    ok "Restored from $REPO_URL ($DEST/, $(git -C "$WORK" log -1 --format=%cs -- "$DEST"))."
}

case "${1:-}" in
    --install) do_install ;;
    --restore) restore ;;
    "")        backup ;;
    *)         fail "Usage: $0 [--install|--restore]" ;;
esac
