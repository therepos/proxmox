#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/setup-backup.sh?$(date +%s))"
# Purpose: Nightly encrypted backup of app data (and chosen folders) to a USB drive and/or OneDrive, with restore
# =============================================================================
# Usage:
#   setup-backup                   Interactive menu (Docker VM; on the PVE host: pass a USB drive to the VM)
#   setup-backup run               Back up now (what the nightly timer runs)
#   setup-backup restore <app>     Restore one app's data: exit 0 restored, 3 no backup, other failure
#
# Stored on this machine (root only, mode 600):
#   /etc/setup-backup/backup.env   Backup password, time, destinations and what to back up
#   /etc/setup-backup/rclone.conf  OneDrive sign-in
#   /etc/homelab/mail.env          Alert email settings (shared with setup-portainer.sh)
# Backups: <USB drive>/homelab-backup and OneDrive:/homelab-backup (restic repositories)
# =============================================================================

set -euo pipefail

# --- Settings ----------------------------------------------------------------
APPS_DIR="${APPS_DIR:-/mnt/sec/apps}"
CONF_DIR="${CONF_DIR:-/etc/setup-backup}"
CONF="$CONF_DIR/backup.env"
RCLONE_CONFIG="${RCLONE_CONFIG:-$CONF_DIR/rclone.conf}"
MAIL_CONF="${MAIL_CONF:-/etc/homelab/mail.env}"
PORTAINER_BACKUP_ENV="/etc/portainer-setup/backup.env"
STATE_DIR="${STATE_DIR:-/var/lib/setup-backup}"
USB_MNT="${USB_MNT:-/mnt/backup-usb}"
FSTAB="${FSTAB:-/etc/fstab}"
REPO_NAME="homelab-backup"
SNAP_HOST="homelab"            # fixed, so a rebuilt VM finds its old snapshots
BACKUP_TIME_DEFAULT="03:00"
UNIT="setup-backup"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SCRIPT_URL="https://github.com/therepos/proxmox/raw/main/apps/setup-backup.sh"
# Re-downloadable or throwaway data, never backed up
EXCLUDES="${EXCLUDES:-.cache
$APPS_DIR/comfyui/models
$APPS_DIR/comfyui/python
$APPS_DIR/comfyui/cache
$APPS_DIR/ollama/models}"
export APPS_DIR RCLONE_CONFIG STATE_DIR USB_MNT REPO_NAME SNAP_HOST EXCLUDES

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

# True only if a controlling terminal can actually be opened.
have_tty(){ [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }
ask(){ # ask "prompt" [default] -> answer on stdout
  local p="$1" def="${2:-}" in=""
  have_tty || fail "No terminal to ask: $p"
  if [[ -n "$def" ]]; then read -rp "$p (default: $def): " in </dev/tty; else read -rp "$p: " in </dev/tty; fi
  printf '%s' "${in:-$def}"
}
askv(){ # askv "  LABEL" [default] [e.g.] -> prompts "  LABEL (default: x) = "
  local l="$1" def="${2:-}" eg="${3:-}" in="" h=""
  have_tty || fail "No terminal to ask: $l"
  [[ -n "$eg" ]] && h="e.g. $eg"
  [[ -n "$def" ]] && h="${h:+$h, }default: $def"
  read -rp "$l${h:+ ($h)} = " in </dev/tty
  printf '%s' "${in:-$def}"
}
ask_secret(){ local in=""; have_tty || fail "No terminal to ask: $1"
  read -rsp "$1: " in </dev/tty; echo >/dev/tty; printf '%s' "$in"; }
ask_new_secret(){ # asks twice
  local a b
  while true; do
    a="$(ask_secret "$1")"; b="$(ask_secret "Confirm password")"
    [[ -n "$a" ]] || { echo "Password cannot be empty." >/dev/tty; continue; }
    [[ "$a" == "$b" ]] || { echo "Passwords do not match." >/dev/tty; continue; }
    printf '%s' "$a"; return
  done
}
yesno(){ # yesno "prompt" default(y|n); no terminal -> default
  local in d="${2:-y}"
  have_tty || { [[ "$d" == y ]]; return; }
  read -rp "$1 [$([[ $d == y ]] && echo Y/n || echo y/N)]: " in </dev/tty
  in="${in:-$d}"; [[ "${in,,}" == y* ]]
}
write_env(){ # write_env file KEY=VALUE ...  (mode 600, values single-quoted)
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"; chmod 700 "$(dirname "$f")"
  ( umask 077; : >"$f.tmp"
    for kv in "$@"; do printf "%s='%s'\n" "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed "s/'/'\\\\''/g")" >>"$f.tmp"; done )
  mv "$f.tmp" "$f"; chmod 600 "$f"
}
# shellcheck disable=SC1090  # env file path is a runtime argument
load_env(){ [[ -f "$1" ]] && { set -a; . "$1"; set +a; }; return 0; }

is_pve(){ [[ -f /etc/pve/.version ]] || command -v pveversion >/dev/null 2>&1; }

# --- Engine: restic runs, container pausing, restore, mail ---------------------
engine(){ # engine <action> [args]  — secrets are passed via environment, never argv
  local py rc=0; py="$(mktemp)"
  cat >"$py" <<'PY'
import datetime, json, os, shutil, signal, smtplib, subprocess, sys, tempfile, time
from email.message import EmailMessage

def _bye(sig, frame): raise SystemExit(128 + sig)   # so finally blocks unpause/restart containers
for _s in (signal.SIGTERM, signal.SIGHUP): signal.signal(_s, _bye)

E = os.environ
APPS = E["APPS_DIR"]
LABEL = {"usb": "USB drive", "onedrive": "OneDrive"}
EXCL = [x for x in E.get("EXCLUDES", "").split("\n") if x]
TTY = sys.stderr.isatty()

class Fail(Exception): pass
C = sys.stdout.isatty() or bool(E.get("FORCE_COLOR"))
def ok(m): print(("\033[1;32m[ OK ]\033[0m " if C else "[ OK ] ") + m, flush=True)
def info(m): print(("\033[1;36m[INFO]\033[0m " if C else "[INFO] ") + m, flush=True)
def warn(m): print(("\033[1;33m[WARN]\033[0m " if C else "[WARN] ") + m, file=sys.stderr, flush=True)

def repo(dest):
    return f"{E['USB_MNT']}/{E['REPO_NAME']}" if dest == "usb" else f"rclone:onedrive:{E['REPO_NAME']}"

def restic(dest, *args, check=True, stream=None):
    env = dict(E, RESTIC_PASSWORD=E.get("BACKUP_PASSWORD", ""), RESTIC_PROGRESS_FPS="0.5")
    cmd = ["restic", "-r", repo(dest), "--no-cache" if dest == "usb" else "--cleanup-cache", *args]
    if stream:
        ef = tempfile.TemporaryFile(mode="w+")
        p = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=ef, text=True)
        last = None
        for l in p.stdout:
            try: m = json.loads(l)
            except ValueError: continue
            if m.get("message_type") == "summary": last = m
            elif m.get("message_type") == "status" and TTY:
                done, tot = m.get("bytes_done", 0), m.get("total_bytes", 0) or 1
                sys.stderr.write(f"\r       {stream}: {100 * done // tot:3d}%  ({gb(done)} of {gb(tot)})   ")
        p.wait(); ef.seek(0); err = ef.read(); ef.close()
        if TTY: sys.stderr.write("\r" + " " * 70 + "\r")
        if p.returncode not in (0, 3): raise Fail(short(err) or f"restic exit {p.returncode}")
        if not last: raise Fail("restic gave no result")
        return last, p.returncode
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if check and r.returncode != 0: raise Fail(short(r.stderr) or f"restic exit {r.returncode}")
    return r

def short(err):
    lines = [l.strip() for l in (err or "").strip().splitlines() if l.strip()]
    fatal = [l for l in lines if l.startswith("Fatal:") or "rror" in l]
    return (fatal or lines or [""])[0][:300]

def gb(n): return f"{n/1e9:.1f} GB" if n >= 1e8 else f"{n/1e6:.0f} MB"

def dests(): return [d for d in E.get("DESTS", "").split() if d in LABEL]

def items(dest):
    """[(name, path)] for one destination: every app folder except skipped ones, plus chosen folders."""
    skip = set(x for x in E.get(f"SKIP_APPS_{dest}", "").split("|") if x)
    out = []
    if os.path.isdir(APPS):
        for n in sorted(os.listdir(APPS)):
            p = os.path.join(APPS, n)
            if not n.startswith(".") and os.path.isdir(p) and n not in skip: out.append((n, p))
    for f in E.get(f"FOLDERS_{dest}", "").split("|"):
        if f: out.append((os.path.basename(f.rstrip("/")) or f, f))
    return out

def excluded(path, root):
    return os.path.basename(path) in [x for x in EXCL if "/" not in x] or path in EXCL

def walk_size(root):
    total = files = 0
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if not excluded(os.path.join(d, x), root)]
        for f in fs:
            try: total += os.lstat(os.path.join(d, f)).st_size; files += 1
            except OSError: pass
    return total, files

def has_files(root):
    for d, dirs, fs in os.walk(root):
        dirs[:] = [x for x in dirs if not excluded(os.path.join(d, x), root)]
        if fs: return True
    return False

def excl_args(path):
    a = ["--exclude-caches"]
    for x in EXCL:
        if "/" not in x: a.append(f"--exclude={x}")
        elif x.startswith(path.rstrip("/") + "/"): a.append(f"--exclude={x}")
    return a

# ---- Docker ----
def containers_using(path):
    """Running containers with a bind mount at or below path."""
    if not shutil.which("docker"): return []
    r = subprocess.run(["docker", "ps", "-q"], capture_output=True, text=True)
    ids = r.stdout.split()
    if not ids: return []
    info = json.loads(subprocess.run(["docker", "inspect", *ids], capture_output=True, text=True).stdout or "[]")
    p = path.rstrip("/")
    out = []
    for c in info:
        for m in c.get("Mounts", []):
            s = (m.get("Source") or "").rstrip("/")
            if s == p or s.startswith(p + "/"):
                out.append(c["Name"].lstrip("/")); break
    return out

def docker(*args): subprocess.run(["docker", *args], capture_output=True)

# ---- State and mail ----
def state():
    try: return json.load(open(os.path.join(E["STATE_DIR"], "state.json")))
    except Exception: return {}
def save_state(**kw):
    os.makedirs(E["STATE_DIR"], exist_ok=True)
    s = state(); s.update(kw)
    json.dump(s, open(os.path.join(E["STATE_DIR"], "state.json"), "w"))

def send_mail(subject, body):
    need = ["SMTP_HOST", "SMTP_USERNAME", "SMTP_PASSWORD", "ALERT_TO"]
    if not all(E.get(k) for k in need): return False
    m = EmailMessage(); m["Subject"] = subject; m["From"] = E.get("SMTP_FROM") or E["SMTP_USERNAME"]; m["To"] = E["ALERT_TO"]
    m.set_content(body)
    port = int(E.get("SMTP_PORT") or 587)
    if (E.get("SMTP_SECURITY") or "starttls") == "force_tls" or port == 465:
        s = smtplib.SMTP_SSL(E["SMTP_HOST"], port, timeout=30)
    else:
        s = smtplib.SMTP(E["SMTP_HOST"], port, timeout=30)
        if (E.get("SMTP_SECURITY") or "starttls") != "off": s.starttls()
    with s:
        s.login(E["SMTP_USERNAME"], E["SMTP_PASSWORD"]); s.send_message(m)
    return True

# ---- Backup ----
def reachable(dest):
    if dest == "usb":
        try: os.listdir(E["USB_MNT"])          # triggers the automount
        except OSError: pass
        if not os.path.isdir(repo(dest)): raise Fail("USB drive not connected")
    restic(dest, "cat", "config")

def line(action, mb, detail): return f"{action:<8} {mb:.1f} MB  {detail}"

def backup_dest(dest):
    reachable(dest)
    restic(dest, "unlock", check=False)
    snaps = json.loads(restic(dest, "snapshots", "--json").stdout or "[]")
    seen = set(p for s in snaps for p in s.get("paths", []))
    added = 0; marks = []; errors = []; empty = []
    its = items(dest)
    apps = [p for n, p in its if p.startswith(APPS.rstrip("/") + "/")]
    if not os.path.isdir(APPS) or (apps and not any(os.path.isdir(p) and has_files(p) for p in apps)):
        raise Fail(f"{APPS} is missing or empty (is /mnt/sec mounted?); nothing backed up")
    for name, path in its:
        if not os.path.isdir(path) or not has_files(path):
            empty.append(name); continue            # never let an empty folder become the latest backup
        paused = containers_using(path)
        for c in paused: docker("pause", c)
        try:
            tag = f"app:{name}" if path.startswith(APPS.rstrip("/") + "/") else "folder"
            s, rc = restic(dest, "backup", path, "--json", "--host", E["SNAP_HOST"], "--tag", tag, *excl_args(path),
                           stream=f"{LABEL[dest]}: {name}")
        except Fail as e:
            errors.append(f"{name}: {e}"); continue
        finally:
            for c in paused: docker("unpause", c)
        if rc == 3: errors.append(f"{name}: some files could not be read (rest saved)")
        added += s.get("data_added", 0)
        if path not in seen: marks.append("+" + name)
        elif s.get("files_new", 0) or s.get("files_changed", 0): marks.append("~" + name)
    keep = ["--host", E["SNAP_HOST"], "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6"]
    if datetime.date.today().isoweekday() == 7 or E.get("PRUNE") == "1": keep.append("--prune")
    try: restic(dest, "forget", *keep)
    except Fail as e: errors.append(f"cleanup: {e}")
    detail = " ".join(marks) or "No changes"
    if empty: detail += f" (empty, skipped: {' '.join(empty)})"
    if errors: raise Fail("; ".join(errors) + (f" (saved: {detail})" if marks else ""))
    return added / 1e6, detail

def a_run():
    host = os.uname().nodename
    ds = dests()
    if not ds: raise Fail("No backup destination set up")
    if datetime.date.today().isoweekday() == 7 and E.get("NIGHTLY") == "1":
        for c in (["restic", "self-update"], ["rclone", "selfupdate"]):
            if shutil.which(c[0]): subprocess.run(c, capture_output=True)
    lines = []; failed = []
    for d in ds:
        try:
            mb, detail = backup_dest(d)
            lines.append(line("Saved", mb, f"{LABEL[d]}: {detail}"))
            if E.get("NIGHTLY") == "1": print(lines[-1], flush=True)
            else: ok(f"{LABEL[d]}: saved {mb:.1f} MB ({detail})")
        except Exception as e:
            msg = str(e) if isinstance(e, Fail) else f"{type(e).__name__}: {e}"
            lines.append(line("Failed", 0.0, f"{LABEL[d]}: {msg}")); failed.append((d, msg))
            if E.get("NIGHTLY") == "1": print(lines[-1], flush=True)
            else: warn(f"{LABEL[d]}: {msg}")
    save_state(last_run=time.time(), last_result="ok" if not failed else "failed")
    if failed:
        hints = []
        for d, msg in failed:
            if "not connected" in msg: hints.append("Plug the USB drive back in; it reconnects by itself.")
            elif d == "onedrive" and ("token" in msg.lower() or "401" in msg or "auth" in msg.lower()):
                hints.append("Run setup-backup → Settings → Destinations → Reconnect OneDrive.")
            elif "password" in msg.lower(): hints.append("Run setup-backup → Settings → Change backup password.")
        try: send_mail(f"[{host}] App data backup FAILED", "\n".join(lines) + ("\n\nFix: " + " ".join(hints) if hints else "") + "\n")
        except Exception as m: print(f"alert email failed too: {m}", file=sys.stderr)
        sys.exit(1)
    if E.get("NIGHTLY") == "1" and time.time() - state().get("last_ok_mail", 0) > 7 * 86400 - 3600:
        try:
            if send_mail(f"[{host}] App data backups OK", "App data backup is working.\n" + "\n".join(lines) + "\n"):
                save_state(last_ok_mail=time.time())
        except Exception as m: print(f"weekly email failed: {m}", file=sys.stderr)

def a_status():
    st = state()
    if not st.get("last_run"): print("never run"); return
    t = datetime.datetime.fromtimestamp(st["last_run"]).strftime("%Y-%m-%d %H:%M")
    print(f"last: {t} {'OK' if st.get('last_result') == 'ok' else 'FAILED'}")

# ---- Restore ----
def latest(path):
    """Newest snapshot of path across destinations: (dest, snapshot) or (None, None)."""
    best = (None, None); down = []; usb = None
    for d in dests():
        try:
            reachable(d)
            snaps = json.loads(restic(d, "snapshots", "--json", "--path", path).stdout or "[]")
        except Fail as e:
            down.append(f"{LABEL[d]}: {e}"); continue
        for s in snaps:
            if best[1] is None or s["time"] > best[1]["time"]: best = (d, s)
            if d == "usb" and (usb is None or s["time"] > usb["time"]): usb = s
    if best[1] is None and down: raise Fail("Cannot check backups: " + "; ".join(down))
    if down and best[1] is not None: best = (best[0], dict(best[1], _down=down))
    if best[0] != "usb" and usb and newest(usb) >= newest(best[1]) - 6 * 3600:
        best = ("usb", usb)                  # nearly as new and much faster than the cloud
    return best

def newest(s): return datetime.datetime.fromisoformat(s["time"][:19]).timestamp()

def ask_tty(prompt):
    try: fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError: return False
    try:
        os.write(fd, prompt.encode()); ans = b""
        while not ans.endswith(b"\n"):
            c = os.read(fd, 1)
            if not c: break
            ans += c
        return ans.decode(errors="ignore").strip().lower().startswith("y")
    finally:
        os.close(fd)

def cache_dirs(path):
    out = []
    for d, dirs, fs in os.walk(path):
        if "CACHEDIR.TAG" in fs: out.append(d); dirs[:] = []
    return out

def a_restore(target):
    path = target if target.startswith("/") else os.path.join(APPS, target)
    path = path.rstrip("/")
    name = os.path.basename(path)
    d, snap = latest(path)
    if not snap:
        info(f"No backup of {name}"); sys.exit(3)
    when = snap["time"][:16].replace("T", " ")
    if snap.get("_down"):
        warn("Not reachable, it may hold a newer copy: " + "; ".join(snap["_down"]))
        if not ask_tty(f"Restore {name} from {LABEL[d]} ({when}) anyway? [y/N]: "):
            raise Fail(f"Not restored: {name} (a destination was unreachable)")
    tmp = os.path.join(os.path.dirname(path), f".restore-{name}")
    stopped = containers_using(path)
    for c in stopped: docker("stop", c)
    try:
        shutil.rmtree(tmp, ignore_errors=True)
        r = restic(d, "restore", snap["id"], "--target", tmp, check=False)
        src = tmp + path
        if r.returncode != 0 or not os.path.isdir(src): raise Fail(short(r.stderr) or "restore failed")
        os.makedirs(path, exist_ok=True)
        rs = ["rsync", "-aH", "--numeric-ids", "--delete"]
        for x in EXCL:                       # keep re-downloadable data that was never backed up
            if "/" not in x: rs.append(f"--exclude={x}")
            elif x.startswith(path + "/"): rs.append(f"--exclude=/{x[len(path) + 1:]}")
        for c in cache_dirs(path):           # caches are skipped by backup, so keep them too
            if c != path: rs.append(f"--exclude=/{os.path.relpath(c, path)}")
        r = subprocess.run(rs + [src + "/", path + "/"], capture_output=True, text=True)
        if r.returncode != 0: raise Fail(short(r.stderr) or "copy failed")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        for c in stopped: docker("start", c)
    ok(f"Restored {name} from {LABEL[d]} ({when})")
    kept = [x for x in EXCL if x.startswith(path + "/")]
    if kept: info("Not in backups, kept as they were: " + ", ".join(os.path.relpath(x, path) for x in kept))

def a_backed_up():
    """name<TAB>path<TAB>time<TAB>destination for everything with a backup (the copy a restore would use)."""
    paths = set()
    for d in dests():
        try:
            reachable(d); snaps = json.loads(restic(d, "snapshots", "--json").stdout or "[]")
        except Fail:
            continue
        paths.update(p for s in snaps for p in s.get("paths", []))
    for p in sorted(paths, key=lambda x: (not x.startswith(APPS), x)):
        d, s = latest(p)
        n = os.path.basename(p) if p.startswith(APPS.rstrip("/") + "/") else p
        if s: print(f"{n}\t{p}\t{s['time'][:16].replace('T', ' ')}\t{LABEL[d]}")

def a_sizes(dest):
    for n, p in items(dest):
        b, _ = walk_size(p) if os.path.isdir(p) else (0, 0)
        print(f"{n}\t{p}\t{b}")

def a_repo_exists(dest):
    if dest == "usb": ok = os.path.isfile(repo(dest) + "/config")
    else:
        r = subprocess.run(["rclone", "lsf", f"onedrive:{E['REPO_NAME']}/config"], capture_output=True, text=True)
        ok = r.returncode == 0 and r.stdout.strip() == "config"
    sys.exit(0 if ok else 2)

def a_check_repo(dest):
    """0 = repo opens with the password, 1 = wrong password or unreachable."""
    r = restic(dest, "cat", "config", check=False)
    if r.returncode != 0: print(short(r.stderr), file=sys.stderr); sys.exit(1)

def a_init(dest):
    if dest == "usb": os.makedirs(repo(dest), exist_ok=True)
    restic(dest, "init")

def a_key_id(dest):
    """id of the key the current password opens"""
    keys = json.loads(restic(dest, "key", "list", "--json").stdout or "[]")
    print(next(k["id"] for k in keys if k.get("current")))

def a_key_add(dest):
    pf = os.path.join(E["STATE_DIR"], ".newpw"); os.makedirs(E["STATE_DIR"], exist_ok=True)
    with open(os.open(pf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f: f.write(E["NEW_PASSWORD"])
    try: restic(dest, "key", "add", "--new-password-file", pf)
    finally: os.unlink(pf)

def a_key_remove(dest, kid):
    restic(dest, "key", "remove", kid)

def main():
    a = sys.argv[1:] or [""]
    try:
        if a[0] == "run": a_run()
        elif a[0] == "status": a_status()
        elif a[0] == "restore": a_restore(a[1])
        elif a[0] == "backed-up": a_backed_up()
        elif a[0] == "sizes": a_sizes(a[1])
        elif a[0] == "check-repo": a_check_repo(a[1])
        elif a[0] == "repo-exists": a_repo_exists(a[1])
        elif a[0] == "init": a_init(a[1])
        elif a[0] == "key-id": a_key_id(a[1])
        elif a[0] == "key-add": a_key_add(a[1])
        elif a[0] == "key-remove": a_key_remove(a[1], a[2])
        elif a[0] == "mail-test":
            if not send_mail(f"[{os.uname().nodename}] Test alert", "Alert email is working.\n"): raise Fail("Email settings incomplete")
            print("Test email sent")
        else: raise Fail(f"unknown engine action {a[0]}")
    except Fail as e:
        print(f"[FAIL] {e}", file=sys.stderr); sys.exit(1)

main()
PY
  python3 "$py" "$@" || rc=$?
  rm -f "$py"
  return "$rc"
}

# --- Tools: restic and rclone ----------------------------------------------------
gh_latest(){ # gh_latest owner/repo -> version without the v
  local u
  u="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" 2>/dev/null)" \
    || u="$(curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')" \
    || true
  [[ "$u" == */v* || "$u" == v* ]] || return 1
  printf '%s' "${u##*v}"
}
need_restic(){
  command -v restic >/dev/null && return
  info "Installing restic…"
  command -v curl >/dev/null && command -v bunzip2 >/dev/null || apt-get install -y -qq curl bzip2 >/dev/null
  local v a t; a="$(dpkg --print-architecture)"; v="$(gh_latest restic/restic)" || fail "Could not reach GitHub"
  t="$(mktemp -d)"
  curl -fsSL -o "$t/restic.bz2" "https://github.com/restic/restic/releases/download/v$v/restic_${v}_linux_$a.bz2" \
    && curl -fsSL -o "$t/SHA256SUMS" "https://github.com/restic/restic/releases/download/v$v/SHA256SUMS" \
    || { rm -rf "$t"; fail "restic download failed"; }
  ( cd "$t" && grep " restic_${v}_linux_$a.bz2\$" SHA256SUMS | sed 's/restic_.*$/restic.bz2/' | sha256sum -c --quiet ) \
    || { rm -rf "$t"; fail "restic download is corrupt"; }
  bunzip2 "$t/restic.bz2" && install -m 755 "$t/restic" /usr/local/bin/restic
  rm -rf "$t"
  ok "restic $v installed"
}
need_rclone(){
  command -v rclone >/dev/null && [[ "$(rclone version 2>/dev/null | head -1)" != *v1.6* ]] && return
  info "Installing rclone…"
  command -v unzip >/dev/null && command -v curl >/dev/null || apt-get install -y -qq curl unzip >/dev/null
  local src; src="$(curl -fsSL https://rclone.org/install.sh)" || fail "Could not download the rclone installer"
  bash -c "$src" >/dev/null 2>&1 || command -v rclone >/dev/null || fail "rclone install failed"
  ok "$(rclone version | head -1) installed"
}

# --- USB drive -------------------------------------------------------------------
usb_parts(){ # PATH<TAB>SIZE<TAB>FSTYPE<TAB>UUID<TAB>MODEL for partitions (or whole disks) on USB
  lsblk -J -b -o NAME,PATH,TRAN,SIZE,FSTYPE,UUID,MODEL,TYPE,MOUNTPOINT 2>/dev/null | python3 -c '
import json, sys
def walk(n, usb, model):
    usb = usb or n.get("tran") == "usb"; model = n.get("model") or model
    kids = n.get("children") or []
    if usb and n.get("type") in ("part", "disk") and (n.get("type") == "part" or not kids):
        print("\t".join(str(x or "") for x in (n["path"], n["size"], n.get("fstype"), n.get("uuid"), (model or "USB drive").strip(), n.get("mountpoint"))))
    for k in kids: walk(k, usb, model)
for n in json.load(sys.stdin).get("blockdevices", []): walk(n, False, "")'
}
human(){ numfmt --to=si --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }
automount_unit(){ systemd-escape -p --suffix=automount "$USB_MNT"; }

setup_usb(){ # find the drive, mount it at USB_MNT (automount, survives unplugging)
  local rows=() r dev size fs uuid model mnt
  mapfile -t rows < <(usb_parts)
  if (( ${#rows[@]} == 0 )); then
    warn "No USB drive found in this VM."
    info "Plug it into the server, then on the Proxmox host run:"
    echo "       bash -c \"\$(wget -qLO- $SCRIPT_URL?\$(date +%s))\""
    echo "       and choose Pass USB drive to VM. Then run this again."
    return 1
  fi
  # largest partition with a filesystem
  r="$(printf '%s\n' "${rows[@]}" | awk -F'\t' '$3!=""' | sort -t$'\t' -k2,2n | tail -1)"
  if [[ -z "$r" ]]; then
    r="$(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k2,2n | tail -1)"
    IFS=$'\t' read -r dev size fs uuid model mnt <<<"$r"
    warn "$model ($(human "$size")) at $dev has no filesystem."
    yesno "Erase it and format it for backups (ext4)?" n || return 1
    wipefs -aq "$dev" && mkfs.ext4 -q -F -L homelab-backup "$dev" || fail "Format failed"
    udevadm settle; r="$(usb_parts | awk -F'\t' -v d="$dev" '$1==d')"
  fi
  IFS=$'\t' read -r dev size fs uuid model mnt <<<"$r"
  [[ -n "$uuid" && -n "$fs" ]] || fail "Could not read the drive's ID; unplug it, plug it in again and retry"
  local type="$fs" opts="nofail,x-systemd.automount,x-systemd.idle-timeout=10min,x-systemd.device-timeout=10s"
  case "$fs" in
    ntfs)  if modprobe ntfs3 2>/dev/null; then type=ntfs3; else apt-get install -y -qq ntfs-3g >/dev/null; type=ntfs-3g; fi ;;
    exfat|vfat|ext4|ext3|xfs|btrfs) ;;
    *) fail "Unsupported filesystem '$fs' on $dev" ;;
  esac
  [[ -n "$mnt" && "$mnt" != "$USB_MNT" ]] && umount "$mnt" 2>/dev/null || true
  mkdir -p "$USB_MNT"
  sed -i "\|[[:space:]]${USB_MNT}[[:space:]]|d" "$FSTAB"
  printf 'UUID=%s %s %s %s 0 0\n' "$uuid" "$USB_MNT" "$type" "$opts" >>"$FSTAB"
  systemctl daemon-reload
  systemctl restart "$(automount_unit)" 2>/dev/null || systemctl start "$(automount_unit)" 2>/dev/null || true
  ls "$USB_MNT" >/dev/null 2>&1 || true
  mountpoint -q "$USB_MNT" || fail "Could not mount $dev at $USB_MNT"
  USB_UUID="$uuid"
  ok "USB drive: $model, $(human "$size") ($fs), $(df -h --output=avail "$USB_MNT" | tail -1 | tr -d ' ') free"
}
remove_usb_mount(){
  systemctl stop "$(automount_unit)" 2>/dev/null || true
  umount "$USB_MNT" 2>/dev/null || true
  sed -i "\|[[:space:]]${USB_MNT}[[:space:]]|d" "$FSTAB"
  systemctl daemon-reload
}

# --- OneDrive ----------------------------------------------------------------------
setup_onedrive(){
  need_rclone
  echo ""
  info "OneDrive needs a one-time sign-in from a computer with a browser."
  echo "       On your Windows PC, open PowerShell and paste this line:"
  echo ""
  # shellcheck disable=SC2016  # PowerShell text, shown to the user
  echo '       winget install -e --id Rclone.Rclone; $env:Path=[Environment]::GetEnvironmentVariable("Path","User")+";"+$env:Path; rclone authorize "onedrive"'
  echo ""
  echo "       Sign in to Microsoft in the browser that opens. PowerShell then shows a line"
  echo "       starting with {\"access_token\" ... Copy that whole line and paste it here."
  echo ""
  local tok
  while true; do
    tok="$(ask 'Token (Enter to cancel)')"
    [[ -z "$tok" ]] && return 1
    tok="$(python3 -c '
import base64, json, sys
t = sys.argv[1].strip()
for cand in (t, ):
    try:
        j = json.loads(cand)
    except ValueError:
        try: j = json.loads(base64.b64decode(cand + "=" * (-len(cand) % 4)))
        except Exception: sys.exit(1)
    j = j.get("token", j) if isinstance(j, dict) else j
    if isinstance(j, str): j = json.loads(j)
    if "access_token" not in j: sys.exit(1)
    print(json.dumps(j))' "$tok")" && break
    warn "That is not the token line. Copy the line that starts with {\"access_token\"."
  done
  mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
  info "Connecting to OneDrive…"
  rclone --config "$RCLONE_CONFIG" config delete onedrive >/dev/null 2>&1 || true
  rclone --config "$RCLONE_CONFIG" config create onedrive onedrive token "$tok" config_refresh_token false \
    </dev/null >/dev/null 2>&1 || true
  chmod 600 "$RCLONE_CONFIG" 2>/dev/null || true
  if ! rclone --config "$RCLONE_CONFIG" about onedrive: >/dev/null 2>&1; then
    warn "OneDrive did not accept the sign-in. Run the PowerShell line again for a fresh token."
    return 1
  fi
  ok "OneDrive connected ($(rclone --config "$RCLONE_CONFIG" about onedrive: 2>/dev/null | awk -F': *' '/^Free/{print $2}' | xargs) free)"
}

# --- Configuration -------------------------------------------------------------------
save_conf(){
  write_env "$CONF" "BACKUP_PASSWORD=${BACKUP_PASSWORD:-}" "BACKUP_TIME=$BACKUP_TIME" "DESTS=${DESTS:-}" \
    "USB_UUID=${USB_UUID:-}" \
    "SKIP_APPS_usb=${SKIP_APPS_usb:-}" "FOLDERS_usb=${FOLDERS_usb:-}" \
    "SKIP_APPS_onedrive=${SKIP_APPS_onedrive:-}" "FOLDERS_onedrive=${FOLDERS_onedrive:-}"
}
configured(){ [[ -n "${DESTS:-}" && -n "${BACKUP_PASSWORD:-}" ]]; }
label(){ case "$1" in usb) echo "USB drive" ;; onedrive) echo "OneDrive" ;; esac; }
has_dest(){ [[ " ${DESTS:-} " == *" $1 "* ]]; }
add_dest(){ has_dest "$1" || DESTS="$(xargs <<<"${DESTS:-} $1")"; export DESTS; }
del_dest(){ DESTS="$(tr ' ' '\n' <<<"${DESTS:-}" | grep -vx "$1" | xargs || true)"; export DESTS; }

prepare_dest(){ # prepare_dest usb|onedrive: connect, then open or create its repository
  case "$1" in
    usb)      setup_usb || return 1 ;;
    onedrive) setup_onedrive || return 1 ;;
  esac
  if engine repo-exists "$1"; then
    info "Found existing backups on $(label "$1")"
    local known="${BACKUP_PASSWORD:-}" pw="${BACKUP_PASSWORD:-}"
    until [[ -n "$pw" ]] && BACKUP_PASSWORD="$pw" engine check-repo "$1" 2>/dev/null; do
      [[ -n "$pw" ]] && warn "Wrong password for the backups on $(label "$1")"
      pw="$(ask_secret "Backup password (Enter to skip $(label "$1"))")"
      [[ -z "$pw" ]] && { BACKUP_PASSWORD="$known"; export BACKUP_PASSWORD; return 1; }
    done
    if [[ -n "${DESTS:-}" && -n "$known" && "$pw" != "$known" ]]; then
      warn "$(label "$1") uses a different password from $(label "${DESTS%% *}"); skipped. One password must open both."
      return 1
    fi
    BACKUP_PASSWORD="$pw"; export BACKUP_PASSWORD
    ok "Password accepted"
  else
    need_password
    engine init "$1" >/dev/null || fail "Could not create the backup on $(label "$1")"
    ok "Backup storage created on $(label "$1")"
  fi
  add_dest "$1"
}

need_password(){
  [[ -n "${BACKUP_PASSWORD:-}" ]] && return
  local pw=""
  if [[ -f "$PORTAINER_BACKUP_ENV" ]]; then
    pw="$(load_env "$PORTAINER_BACKUP_ENV"; printf '%s' "${BACKUP_PASSWORD:-}")"
  fi
  if [[ -n "$pw" ]] && yesno "Use the same password as the Portainer backup?" y; then BACKUP_PASSWORD="$pw"
  else
    info "Backups are encrypted with this password. Keep it in Vaultwarden and on paper: without it nothing can be restored."
    BACKUP_PASSWORD="$(ask_new_secret 'Backup password')"
  fi
  export BACKUP_PASSWORD
}

need_mail(){ [[ -n "${SMTP_HOST:-}" && -n "${SMTP_PASSWORD:-}" && -n "${ALERT_TO:-}" ]] || setup_mail; }
setup_mail(){
  local pw
  echo "Alert email (Enter = default):"
  SMTP_HOST="$(askv '  SMTP_HOST' "${SMTP_HOST:-smtp.zoho.com}")"
  SMTP_PORT="$(askv '  SMTP_PORT' "${SMTP_PORT:-587}")"
  SMTP_SECURITY="${SMTP_SECURITY:-starttls}"
  SMTP_USERNAME="$(askv '  SMTP_USERNAME' "${SMTP_USERNAME:-}" admin@example.com)"
  read -rsp "  SMTP_PASSWORD = " pw </dev/tty; echo >/dev/tty
  SMTP_PASSWORD="${pw:-${SMTP_PASSWORD:-}}"
  ALERT_TO="$(askv '  ALERT_TO' "${ALERT_TO:-$SMTP_USERNAME}")"
  export SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USERNAME SMTP_PASSWORD ALERT_TO
  write_env "$MAIL_CONF" "SMTP_HOST=$SMTP_HOST" "SMTP_PORT=$SMTP_PORT" "SMTP_SECURITY=$SMTP_SECURITY" \
    "SMTP_USERNAME=$SMTP_USERNAME" "SMTP_PASSWORD=$SMTP_PASSWORD" "ALERT_TO=$ALERT_TO"
  engine mail-test || warn "Fix with Settings → Change alert email"
}

# --- What to back up -------------------------------------------------------------------
summary(){ # summary <dest> -> "N apps (+ M folders), SIZE"
  local n=0 f=0 total=0 name path bytes
  while IFS=$'\t' read -r name path bytes; do
    [[ -z "$name" ]] && continue
    if [[ "$path" == "$APPS_DIR/"* ]]; then n=$((n + 1)); else f=$((f + 1)); fi
    total=$((total + bytes))
  done < <(engine sizes "$1")
  printf '%d apps%s, %s' "$n" "$( (( f )) && printf ' + %d folder(s)' "$f")" "$(human "$total")"
}

pick_items(){ # pick_items <dest>: toggle apps, add/remove folders
  local d="$1" var_s="SKIP_APPS_$1" var_f="FOLDERS_$1"
  while true; do
    local skip="|${!var_s:-}|" all=() i=1 n p b in x
    echo ""; echo "What to back up to $(label "$d"):"
    local nm
    for nm in $(find "$APPS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -printf '%f\n' 2>/dev/null | sort); do
      all+=("app|$nm")
    done
    local fl=(); IFS='|' read -ra fl <<<"${!var_f:-}"
    for p in "${fl[@]}"; do [[ -n "$p" ]] && all+=("dir|$p"); done
    local sizes saved="${!var_s:-}"           # sizes of every app, skipped ones too
    printf -v "$var_s" '%s' ""; sizes="$(engine sizes "$d")"; printf -v "$var_s" '%s' "$saved"
    for x in "${all[@]}"; do
      n="${x#*|}"
      if [[ "$x" == app\|* ]]; then p="$APPS_DIR/$n"; else p="$n"; fi
      b="$(awk -F'\t' -v p="$p" '$2==p{print $3}' <<<"$sizes")"
      if [[ "$x" == app\|* ]]; then
        printf '  %2d) [%s] %-24s %s\n' "$i" "$([[ "$skip" == *"|$n|"* ]] && echo ' ' || echo x)" "$n" "$(human "${b:-0}")"
      else
        printf '  %2d) [x] %-24s %s\n' "$i" "$n" "$(human "${b:-0}")"
      fi
      i=$((i + 1))
    done
    echo "  Skipped everywhere: $(tr '\n' ' ' <<<"$EXCLUDES" | sed "s|$APPS_DIR/||g")"
    read -rp "  Numbers to switch on/off, a = add a folder, Enter = done: " in </dev/tty || return 0
    [[ -z "$in" ]] && return 0
    if [[ "$in" == a ]]; then
      p="$(ask '  Folder to back up, e.g. /mnt/sec/media/photos')"
      [[ -d "$p" ]] || { warn "Not a folder: $p"; continue; }
      p="${p%/}"; printf -v "$var_f" '%s' "${!var_f:+${!var_f}|}$p"; export "${var_f?}"; continue
    fi
    for x in $in; do
      [[ "$x" =~ ^[0-9]+$ ]] && (( x >= 1 && x <= ${#all[@]} )) || continue
      local it="${all[$((x - 1))]}"; n="${it#*|}"
      if [[ "$it" == app\|* ]]; then
        if [[ "$skip" == *"|$n|"* ]]; then skip="${skip//|$n|/|}"; else skip="$skip$n|"; fi
      else
        local nf; nf="$(tr '|' '\n' <<<"${!var_f}" | grep -vxF "$n" | paste -sd'|' || true)"
        printf -v "$var_f" '%s' "$nf"; export "${var_f?}"
      fi
    done
    skip="$(tr '|' '\n' <<<"$skip" | grep -v '^$' | paste -sd'|' || true)"
    printf -v "$var_s" '%s' "$skip"; export "${var_s?}"
  done
}

# --- Nightly timer --------------------------------------------------------------------------
timer_on(){ systemctl is-enabled "$UNIT.timer" >/dev/null 2>&1; }
timer_enable(){
  cat >"$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=App data backup (setup-backup)
After=docker.service network-online.target
Wants=network-online.target
RequiresMountsFor=$APPS_DIR
[Service]
Type=oneshot
Environment=NIGHTLY=1
ExecStart=/bin/bash -c 'src=\$\$(wget -qLO- "$SCRIPT_URL?\$\$(date +%%s)") || { echo "Failed   0.0 MB  could not download setup-backup.sh from GitHub"; exit 1; }; exec bash -c "\$\$src" setup-backup run'
EOF
  cat >"$UNIT_DIR/$UNIT.timer" <<EOF
[Unit]
Description=Nightly app data backup
[Timer]
OnCalendar=*-*-* ${BACKUP_TIME}:00
Persistent=true
RandomizedDelaySec=5m
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT.timer" >/dev/null 2>&1
  ok "Nightly at ${BACKUP_TIME}, email on failure and a weekly OK"
}
timer_disable(){
  systemctl disable --now "$UNIT.timer" >/dev/null 2>&1 || true
  rm -f "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer"
  systemctl daemon-reload
  ok "Nightly backup turned off"
}

view_log(){ # last 20 results, newest last
  local out
  out="$(journalctl -u "$UNIT.service" -n 300 --no-pager -o short-iso 2>/dev/null \
        | grep -E ': (Saved|Failed) |email' | tail -n 20)" || true
  if [[ -z "$out" ]]; then info "No nightly runs logged yet"; return; fi
  sed -E 's/^([0-9-]+)T([0-9:]{5})[^ ]* [^ ]+ [^:]+: /\1 \2  /' <<<"$out"
}

# --- Flows ---------------------------------------------------------------------------------
choose_dests(){ # sets WANT to "usb onedrive" etc.
  menu "USB drive and OneDrive|recommended: everything on the drive, apps also off-site" \
       "USB drive only" "OneDrive only"
  case "$CHOICE" in
    "USB drive and OneDrive") WANT="usb onedrive" ;;
    "USB drive only")         WANT="usb" ;;
    "OneDrive only")          WANT="onedrive" ;;
  esac
}

connect(){ # connect: destinations and password only (used before a restore)
  local d
  choose_dests
  need_restic
  DESTS=""
  for d in $WANT; do prepare_dest "$d" || warn "$(label "$d") skipped"; done
  [[ -n "$DESTS" ]] || fail "No backup destination available"
  BACKUP_TIME="${BACKUP_TIME:-$BACKUP_TIME_DEFAULT}"
  save_conf
}

flow_setup(){
  banner "Backup: set up"
  connect
  echo ""
  local d
  for d in $DESTS; do printf '  %-10s %s\n' "$(label "$d"):" "$(summary "$d")"; done
  echo "  Nightly    ${BACKUP_TIME}, keeps 7 daily, 4 weekly, 6 monthly versions"
  echo ""
  if ! yesno "Use these?" y; then
    for d in $DESTS; do pick_items "$d"; done
  fi
  has_dest usb && info "To add other folders to the USB drive (e.g. photos): Settings → What to back up"
  save_conf
  need_mail
  timer_enable
  info "First backup now (the first one takes longest)…"
  engine run || warn "First backup had problems; see above"
}

pick_restore(){
  local rows=() opts=() r name path when where
  info "Looking for backups…"
  mapfile -t rows < <(engine backed-up)
  (( ${#rows[@]} )) || { warn "No backups found"; return; }
  for r in "${rows[@]}"; do IFS=$'\t' read -r name path when where <<<"$r"; opts+=("$name|$when, $where"); done
  menu "${opts[@]}" "Back"
  case "$CHOICE" in
    "Back") return ;;
    *) for r in "${rows[@]}"; do IFS=$'\t' read -r name path when where <<<"$r"
         [[ "$name" == "$CHOICE" ]] && break; done
       warn "This replaces $path with the backup from $when ($where). Its containers stop while it restores."
       yesno "Continue?" n || { info "Cancelled."; return; }
       engine restore "$path" || true ;;
  esac
}

menu_dests(){
  local opts=()
  if has_dest usb; then opts+=("Remove USB drive"); else opts+=("Add USB drive"); fi
  if has_dest onedrive; then opts+=("Reconnect OneDrive" "Remove OneDrive"); else opts+=("Add OneDrive"); fi
  menu "${opts[@]}" "Back"
  case "$CHOICE" in
    "Add USB drive")      need_restic; prepare_dest usb && save_conf ;;
    "Remove USB drive")   yesno "Stop backing up to the USB drive? (backups on it are kept)" n || return 0
                          del_dest usb; remove_usb_mount; save_conf; ok "USB drive removed" ;;
    "Add OneDrive"|"Reconnect OneDrive") need_restic; prepare_dest onedrive && save_conf ;;
    "Remove OneDrive")    yesno "Stop backing up to OneDrive? (backups there are kept)" n || return 0
                          del_dest onedrive; rm -f "$RCLONE_CONFIG"; save_conf; ok "OneDrive removed" ;;
    "Back") return 0 ;;
    *) ;;
  esac
}

menu_settings(){
  echo "Settings:"
  menu "Destinations|$(for d in ${DESTS:-}; do printf '%s  ' "$(label "$d")"; done)" "What to back up" \
       "Change backup password" "Change backup time" "Change alert email" \
       "Shortcut|[$(shortcut_state)]  type '$(shortcut_name)' in a new shell" "Back"
  case "$CHOICE" in
    "Destinations")    menu_dests ;;
    "What to back up") local d; for d in $DESTS; do pick_items "$d"; done; save_conf; ok "Saved" ;;
    "Change backup password")
       local np d; local -A old=()
       np="$(ask_new_secret 'New backup password')"
       for d in $DESTS; do old[$d]="$(engine key-id "$d")" || fail "$(label "$d") not reachable; nothing changed"; done
       for d in $DESTS; do   # both passwords work until every destination has the new one
         NEW_PASSWORD="$np" engine key-add "$d" || fail "Could not add it on $(label "$d"); the old password still works everywhere"
       done
       BACKUP_PASSWORD="$np"; export BACKUP_PASSWORD; save_conf
       for d in $DESTS; do engine key-remove "$d" "${old[$d]}" || warn "Old password still also works on $(label "$d")"; done
       ok "Changed for all backups, old ones included. Update it in Vaultwarden." ;;
    "Change backup time") local t
       while true; do
         t="$(ask "Backup time, 24h server time $(date +%Z)" "$BACKUP_TIME")"
         [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
         echo "Use HH:MM, e.g. 03:00" >/dev/tty
       done
       BACKUP_TIME="$t"; save_conf
       if timer_on; then timer_enable; else ok "Saved. Turn on nightly backup in the main menu."; fi ;;
    "Change alert email") setup_mail ;;
    "Shortcut") shortcut_toggle ;;
    "Back") return 0 ;;
  esac
}

guide(){
  banner "Backup: guide"
  cat <<EOF
  Where      USB drive: $USB_MNT/$REPO_NAME   OneDrive: /$REPO_NAME
             Encrypted restic backups; the files are not readable without the password.
  What       Each folder in $APPS_DIR, plus folders you add. Skipped: models, caches.
  When       Nightly at ${BACKUP_TIME:-$BACKUP_TIME_DEFAULT}. Keeps 7 daily, 4 weekly, 6 monthly versions.
  Check      View log, or the weekly "Backups OK" email.
  Restore    One app: Restore in this menu.
             New server: setup-portainer.sh → Restore → Settings and app data
             (it asks for this backup's password once).
  Unplugging The USB drive is safe to unplug 10 minutes after a backup; it reconnects by itself.
  Undo       Uninstall in this menu. Backups on the drive and OneDrive are kept.
EOF
}

do_uninstall(){
  yesno "Stop app data backups and remove their settings from this machine? (backups are kept)" n || { info "Cancelled."; return; }
  timer_on && timer_disable
  remove_usb_mount
  rm -rf "$CONF_DIR" "$STATE_DIR"
  ok "Uninstalled. Backups on the USB drive and OneDrive are kept. Alert email settings kept: $MAIL_CONF"
}

# --- Proxmox host: pass the USB drive to the VM --------------------------------------------
usb_devices(){ # VID:PID<TAB>name for USB mass-storage devices
  local d c
  for d in "${SYS_USB:-/sys/bus/usb/devices}"/*; do
    [[ -f "$d/idVendor" ]] || continue
    for c in "$d"/*:*/bInterfaceClass; do
      [[ -f "$c" && "$(cat "$c")" == 08 ]] || continue
      printf '%s:%s\t%s %s\n' "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" \
        "$(cat "$d/manufacturer" 2>/dev/null || true)" "$(cat "$d/product" 2>/dev/null || echo 'USB drive')"
      break
    done
  done | sort -u
}
host_menu(){
  banner "Backup (Proxmox host)"
  info "Backups run on the Docker VM. Here you can give it the USB drive."
  menu "Pass USB drive to VM|the VM sees the drive; it reconnects after unplugging" "Remove USB drive from VM"
  case "$CHOICE" in
    "Pass USB drive to VM")     host_pass ;;
    "Remove USB drive from VM") host_unpass ;;
  esac
}
pick_vm(){ # sets VMID
  local opts=() r
  mapfile -t opts < <(qm list 2>/dev/null | awk 'NR>1{print $1" "$2"|"$3}')
  (( ${#opts[@]} )) || fail "No VMs found"
  echo "Which VM runs the backups (your Docker VM)?"
  menu "${opts[@]}"
  case "$CHOICE" in
    *) r="$CHOICE"; VMID="${r%% *}" ;;
  esac
}
host_pass(){
  local devs=() opts=() id name n used i
  mapfile -t devs < <(usb_devices)
  (( ${#devs[@]} )) || fail "No USB drive found. Plug it into the server and try again."
  for i in "${devs[@]}"; do opts+=("${i#*$'\t'} (${i%%$'\t'*})"); done
  echo "Which drive?"
  menu "${opts[@]}"
  case "$CHOICE" in
    *) id="${CHOICE##*(}"; id="${id%)}"; name="${CHOICE% (*}" ;;
  esac
  pick_vm
  if qm config "$VMID" | grep -qE "^usb[0-9]+: host=$id"; then ok "$name is already passed to VM $VMID"; return; fi
  used="$(qm config "$VMID" | sed -n 's/^usb\([0-9]*\):.*/\1/p')"
  for n in $(seq 0 13); do grep -qx "$n" <<<"$used" || break; done
  qm set "$VMID" -"usb$n" "host=$id,usb3=1" >/dev/null || fail "Could not pass the drive to VM $VMID"
  ok "$name passed to VM $VMID (usb$n)"
  info "In the VM, run setup-backup and choose Set up. If the drive is not found there, restart the VM once."
}
host_unpass(){
  local opts=() l
  pick_vm
  mapfile -t opts < <(qm config "$VMID" | sed -n 's/^\(usb[0-9]*\): host=\([0-9a-f:]*\).*/\1 \2/p')
  (( ${#opts[@]} )) || { info "VM $VMID has no USB devices"; return; }
  menu "${opts[@]}" "Back"
  case "$CHOICE" in
    "Back") return ;;
    *) l="${CHOICE%% *}"; qm set "$VMID" -delete "$l" >/dev/null && ok "Removed $l from VM $VMID" ;;
  esac
}

# --- Main --------------------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "Run as root (or via sudo)."

if is_pve; then
  have_tty || fail "Run this on the Docker VM. On the Proxmox host it only passes a USB drive to the VM."
  host_menu; exit 0
fi

load_env "$CONF"
load_env "$MAIL_CONF"
BACKUP_TIME="${BACKUP_TIME:-$BACKUP_TIME_DEFAULT}"
export BACKUP_PASSWORD DESTS SKIP_APPS_usb FOLDERS_usb SKIP_APPS_onedrive FOLDERS_onedrive
command -v python3 >/dev/null || fail "python3 not found"

run_action(){
  case "$1" in
    run)
      configured || fail "Not set up yet; run setup-backup in a terminal"
      need_restic; engine run ;;
    restore)
      [[ -n "${2:-}" ]] || fail "Usage: setup-backup restore <app>"
      [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "Not an app name: $2"
      if ! configured; then
        have_tty || exit 3
        info "App data backups are not connected on this machine yet."
        yesno "Connect to your backups now (USB drive or OneDrive)?" y || exit 3
        connect
        info "Nightly backup stays off until you turn it on in setup-backup (after your apps are back)."
      fi
      need_restic
      local rc=0; engine restore "$2" || rc=$?
      exit "$rc" ;;
    help|-h|--help) printf '%s\n' "Usage: setup-backup [run | restore <app>]" ;;
    *) fail "Unknown action '$1' (try: run, restore <app>)" ;;
  esac
}

args=("$@")
if [[ $# -eq 0 ]]; then
  case "$0" in run|restore|help|-h|--help) args=("$0") ;; esac
fi
if (( ${#args[@]} )); then run_action "${args[@]}"; exit 0; fi
have_tty || fail "No terminal for the menu; pass an action (run, restore <app>)."

main_menu(){
  banner "Backup"
  if ! configured; then
    info "Not set up"
    menu "Set up|choose where to back up and what" "Guide"
    case "$CHOICE" in
      "Set up") flow_setup ;;
      "Guide")  guide ;;
    esac
    return
  fi
  local toggle st
  st="$(engine status 2>/dev/null || echo '?')"
  if timer_on; then ok "Nightly backup: ON at ${BACKUP_TIME} (${st})"; toggle="Turn off nightly backup"
  else info "Nightly backup: OFF (${st})"; toggle="Turn on nightly backup"; fi
  menu "Back up now" "Restore" "$toggle" "View log" "Settings" "Guide" "Uninstall"
  case "$CHOICE" in
    "Back up now") need_restic; engine run || true ;;
    "Restore")     need_restic; pick_restore ;;
    "$toggle")     if timer_on; then timer_disable; else need_mail; timer_enable; fi ;;
    "View log")    view_log ;;
    "Settings")    menu_settings ;;
    "Guide")       guide ;;
    "Uninstall")   do_uninstall ;;
  esac
}

main_menu
