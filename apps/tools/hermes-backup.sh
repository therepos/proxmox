#!/usr/bin/env bash
# Installed by hermes-setup.sh, menu option "Back up to GitHub". Not run directly.
# Purpose: Nightly backup of Hermes skills, scripts, jobs, config and memories to a private GitHub repo (run inside the Hermes LXC)
# =============================================================================
# Usage (inside the Hermes LXC):
#   hermes-backup.sh --install   install git/rsync/cron, schedule 03:30 daily, run once
#   hermes-backup.sh             back up now (what the schedule runs)
#
# Needs a GitHub deploy key with write access at /root/.ssh/hermes_backup.
# Secrets (.env, auth.json, google_*.json), databases, logs and caches are never copied.
#
# Settings come from /etc/hermes-backup.conf (written by hermes-setup.sh) or the environment:
#   HERMES_BACKUP_REPO   git URL, e.g. git@github.com:owner/repo.git   (required)
#   HERMES_BACKUP_DIR    folder inside the repo                         (default backup/hermes)
#   HERMES_DATA          Hermes data folder                             (default /opt/hermes/data)
# =============================================================================
set -euo pipefail

ok()   { printf '[ OK ] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

CONF=/etc/hermes-backup.conf
# shellcheck disable=SC1090
[[ -f "$CONF" ]] && . "$CONF"

REPO_URL="${HERMES_BACKUP_REPO:-}"
DEST="${HERMES_BACKUP_DIR:-backup/hermes}"
SRC="${HERMES_DATA:-/opt/hermes/data}"
KEY=/root/.ssh/hermes_backup
WORK=/root/hermes-backup-repo
SELF=/usr/local/bin/hermes-backup.sh
CRON=/etc/cron.d/hermes-backup

# Tokens that must never reach the repo, even inside a skill or script.
SECRET_RE='sk-ant-[A-Za-z0-9_-]{20,}|sk-or-v1-[A-Za-z0-9]{20,}|AIza[0-9A-Za-z_-]{35}|"refresh_token": *"1//|-----BEGIN [A-Z ]*PRIVATE KEY-----'

do_install() {
    [[ $EUID -eq 0 ]] || fail "Run as root."
    [[ -f "$KEY" ]] || fail "Deploy key $KEY not found."
    info "Installing git, rsync and cron..."
    apt-get install -y git rsync cron >/dev/null 2>&1 || fail "apt-get install failed."
    [[ "$(realpath "$0")" == "$SELF" ]] || install -m 755 "$0" "$SELF"
    echo "30 3 * * * root $SELF >>/var/log/hermes-backup.log 2>&1" >"$CRON"
    chmod 644 "$CRON"
    ok "Scheduled daily at 03:30 (log: /var/log/hermes-backup.log)."
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

backup() {
    [[ -n "$REPO_URL" ]] || fail "No repo set. Configure it from hermes-setup.sh."
    export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

    # Start over if the repo was changed since the last run.
    if [[ -d "$WORK/.git" && "$(git -C "$WORK" config --get remote.origin.url)" != "$REPO_URL" ]]; then
        rm -rf "$WORK"
    fi
    if [[ ! -d "$WORK/.git" ]]; then
        info "Cloning $REPO_URL (only $DEST/)..."
        git clone -q --filter=blob:none --sparse "$REPO_URL" "$WORK"
        git -C "$WORK" config user.name "hermes-backup"
        git -C "$WORK" config user.email "hermes-backup@localhost"
    fi
    cd "$WORK"
    git sparse-checkout set "$DEST"
    git pull -q --rebase

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

case "${1:-}" in
    --install) do_install ;;
    "")        backup ;;
    *)         fail "Usage: $0 [--install]" ;;
esac
