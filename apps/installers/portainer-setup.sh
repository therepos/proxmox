#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/portainer-setup.sh?$(date +%s))"
# Purpose: Installs Portainer, deploys stacks from the docker repo, and backs Portainer up to GitHub nightly
# =============================================================================
# Usage:
#   portainer-setup                      Interactive menu
#   portainer-setup install              Install and start Portainer (setup continues in the menu)
#   portainer-setup update               Pull latest image, recreate container, refresh this script
#   portainer-setup backup               Back up Portainer to GitHub now
#   portainer-setup add [app ...]        Deploy apps from the docker repo (no names: pick from a list)
#   portainer-setup uninstall            Remove Portainer (needs CONFIRM=yes when run without a terminal)
#   portainer-setup backup-run           Nightly job (called by the systemd timer)
#
# Non-interactive (for Webmin custom commands):
#   bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/portainer-setup.sh?$(date +%s))" -- update
#
# Note: keep the `--` placeholder — bash assigns the first word after the
#       script body to $0, not $1, so without it the action is lost.
#
# Stored on this machine (root only, mode 600):
#   /etc/portainer-setup/github.env    GitHub PAT for the docker repo
#   /etc/portainer-setup/portainer.env Portainer API token used by the nightly backup
#   /etc/portainer-setup/backup.env    Backup password and nightly backup time
#   /etc/homelab/mail.env              Alert email settings (shared with backup-setup.sh)
# Backups: <docker repo>/backups/portainer/portainer-backup.tar.gz (encrypted; git keeps history)
# =============================================================================

set -euo pipefail

# --- Settings ----------------------------------------------------------------
IMAGE="portainer/portainer-ce:lts"
NAME="portainer"
PORT_HTTPS="9443"
HOST_BIND="${HOST_BIND-/mnt/sec/apps}"   # optional; leave empty to disable. Also the app data folder.
PORTAINER_URL="${PORTAINER_URL:-https://127.0.0.1:${PORT_HTTPS}}"
GH_REPO_DEFAULT="therepos/docker"
GH_BRANCH="main"
BACKUP_FILE="backups/portainer/portainer-backup.tar.gz"
BACKUP_TIME="02:15"         # default; changeable in Settings (stored in backup.env)
CONF_DIR="${CONF_DIR:-/etc/portainer-setup}"
MAIL_CONF="${MAIL_CONF:-/etc/homelab/mail.env}"
STATE_DIR="${STATE_DIR:-/var/lib/portainer-setup}"
SELF_PATH="${SELF_PATH:-/usr/local/sbin/portainer-setup}"
SELF_URL="${SELF_URL:-https://github.com/therepos/proxmox/raw/main/apps/installers/portainer-setup.sh}"
TIMER="portainer-backup"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"

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
# True only if a controlling terminal can actually be opened. Testing -r alone
# is not enough: /dev/tty exists and looks readable even with no controlling
# terminal, and the open then fails at runtime.
have_tty(){ [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; }

asknum(){ # asknum "prompt" "min" "max" "default"
  local p="$1" min="$2" max="$3" def="$4" in
  while true; do
    if have_tty; then
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in </dev/tty || in="$def"
    else
      read -rp "$p [$min-$max, 0 to exit] (default: $def): " in || in="$def"
    fi
    in="${in:-$def}"
    [[ "$in" =~ ^[0-9]+$ ]] || { echo "Enter a number."; continue; }
    (( in==0 || (in>=min && in<=max) )) && { echo "$in"; return; }
  done
}

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
ask_secret(){ # ask_secret "prompt" -> answer on stdout (hidden)
  local in=""
  have_tty || fail "No terminal to ask: $1"
  read -rsp "$1: " in </dev/tty; echo >/dev/tty
  printf '%s' "$in"
}
ask_new_secret(){ # ask_new_secret "prompt" [minlen] -> asks twice
  local a b min="${2:-1}"
  while true; do
    a="$(ask_secret "$1")"; b="$(ask_secret "Confirm password")"
    [[ "$a" == "$b" ]] || { echo "Passwords do not match." >/dev/tty; continue; }
    (( ${#a} >= min )) || { echo "Must be at least $min characters." >/dev/tty; continue; }
    printf '%s' "$a"; return
  done
}
yesno(){ # yesno "prompt" default(y|n)
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
load_env(){ [[ -f "$1" ]] && { set -a; . "$1"; set +a; }; return 0; }

# --- Prechecks ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
command -v docker  >/dev/null || fail "Docker not found"
command -v python3 >/dev/null || fail "python3 not found"
[[ -S /var/run/docker.sock ]] || fail "Docker socket missing: /var/run/docker.sock"
[[ -n "${HOST_BIND}" ]] && mkdir -p "${HOST_BIND}"

load_env "$CONF_DIR/github.env"
load_env "$CONF_DIR/portainer.env"
load_env "$CONF_DIR/backup.env"
load_env "$MAIL_CONF"
GH_REPO="${GH_REPO:-$GH_REPO_DEFAULT}"

exists_container(){ docker ps -a --format '{{.Names}}' | grep -qx "$NAME"; }
timer_on(){ systemctl is-enabled "$TIMER.timer" >/dev/null 2>&1; }

# --- Engine: Portainer, GitHub and mail API calls ------------------------------
engine(){ # engine <action> [args]  — secrets are passed via environment, never argv
  local py rc=0; py="$(mktemp)"
  cat >"$py" <<'PY'
import base64, datetime, hashlib, json, os, re, secrets, smtplib, ssl, string, sys, time
import urllib.error, urllib.request
from email.message import EmailMessage

E = os.environ
P = E.get("PORTAINER_URL", "https://127.0.0.1:9443").rstrip("/")
GHAPI = E.get("GH_API", "https://api.github.com").rstrip("/")
REPO = E.get("GH_REPO", "")
BRANCH = E.get("GH_BRANCH", "main")
BFILE = E.get("BACKUP_FILE", "backups/portainer/portainer-backup.tar.gz")
BMETA = BFILE.rsplit(".tar.gz", 1)[0] + ".json"
COLOR = bool(E.get("FORCE_COLOR") or sys.stdout.isatty())
def c(code, tag, m, err=False):
    s = f"\033[1;{code}m{tag}\033[0m" if COLOR else tag
    print(f"{s} {m}", file=sys.stderr if err else sys.stdout, flush=True)
ok   = lambda m: c(32, "[ OK ]", m)
info = lambda m: c(36, "[INFO]", m)
warn = lambda m: c(33, "[WARN]", m, True)
class Fail(Exception): pass
def fail(m): raise Fail(m)

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
def http(method, url, body=None, headers=None, raw=False, data=None, timeout=600, ctx=CTX):
    h = dict(headers or {})
    if body is not None: data = json.dumps(body).encode(); h.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, method=method, headers=h, data=data)
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        d = r.read()
        return d if raw else (json.loads(d) if d else None)
def errtext(e):
    try: return e.read().decode()[:300]
    except Exception: return str(e)

# ---- Portainer ----
def phdr():
    t = E.get("PORTAINER_TOKEN")
    if not t: fail("No Portainer API token")
    return {"X-API-Key": t}
def api(method, path, body=None, **kw):
    return http(method, P + "/api" + path, body, phdr(), **kw)
def endpoint_id():
    eps = api("GET", "/endpoints")
    if len(eps) == 1: return eps[0]["Id"]
    local = [e for e in eps if str(e.get("URL", "")).startswith("unix://")]
    if len(local) == 1: return local[0]["Id"]
    fail("Several Portainer environments found; cannot pick one automatically")
def stacks(): return api("GET", "/stacks") or []
def wait_up(seconds=120):
    t0 = time.time()
    while time.time() - t0 < seconds:
        try: return http("GET", P + "/api/system/status", timeout=5)["Version"]
        except Exception: time.sleep(2)
    fail(f"Portainer did not answer at {P}")

# ---- GitHub ----
def ghdr(accept="application/vnd.github+json"):
    return {"Authorization": "Bearer " + E.get("GH_PAT", ""), "Accept": accept, "User-Agent": "portainer-setup",
            "X-GitHub-Api-Version": "2022-11-28"}
def repo_url(): return f"https://github.com/{REPO}"
def gh_tree():
    try: t = http("GET", f"{GHAPI}/repos/{REPO}/git/trees/{BRANCH}?recursive=1", headers=ghdr(), timeout=30, ctx=None)
    except urllib.error.HTTPError as e:
        fail(f"GitHub PAT cannot read {REPO} ({e.code}). Needs Repository access: {REPO}, Contents: Read and write")
    return {x["path"] for x in t.get("tree", []) if x.get("type") == "blob"}
def gh_get(path, raw=True):
    return http("GET", f"{GHAPI}/repos/{REPO}/contents/{path}?ref={BRANCH}",
                headers=ghdr("application/vnd.github.raw" if raw else "application/vnd.github+json"),
                raw=raw, timeout=120, ctx=None)
def gh_put(path, content_bytes, message):
    sha = None
    try: sha = gh_get(path, raw=False).get("sha")
    except urllib.error.HTTPError as e:
        if e.code != 404: raise
    body = {"message": message, "content": base64.b64encode(content_bytes).decode(), "branch": BRANCH}
    if sha: body["sha"] = sha
    try: http("PUT", f"{GHAPI}/repos/{REPO}/contents/{path}", body, ghdr(), timeout=300, ctx=None)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403, 404):
            fail(f"GitHub PAT cannot write to {REPO} ({e.code}). Needs Contents: Read and write")
        raise

# ---- Mail ----
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

# ---- tty prompts (stdin is not usable under bash -c "$(wget …)") ----
TTY_FD = None
def tty_in(prompt, secret=False):
    """Read one line from the terminal, byte by byte, so nothing typed ahead is swallowed."""
    global TTY_FD
    if TTY_FD is None:
        try: TTY_FD = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
        except OSError: return None
    os.write(TTY_FD, prompt.encode())
    old = None
    if secret:
        import termios
        try:
            old = termios.tcgetattr(TTY_FD); new = termios.tcgetattr(TTY_FD)
            new[3] &= ~termios.ECHO; termios.tcsetattr(TTY_FD, termios.TCSADRAIN, new)
        except termios.error: old = None
    buf = b""
    try:
        while True:
            ch = os.read(TTY_FD, 1)
            if not ch: return None if not buf else buf.decode()
            if ch == b"\n": break
            buf += ch
    finally:
        if old is not None:
            import termios; termios.tcsetattr(TTY_FD, termios.TCSADRAIN, old); os.write(TTY_FD, b"\n")
    return buf.decode().rstrip("\r")

# ================= actions =================
def a_wait_up():
    print(wait_up())

def a_setup_token():
    # Portainer >= 2.45 prints a one-time setup token in its startup log
    import subprocess
    logs = subprocess.run(["docker", "logs", E.get("NAME", "portainer")], capture_output=True, text=True)
    toks = re.findall(r"setup_token=([0-9a-f]{64})", logs.stdout + logs.stderr)
    print(toks[-1] if toks else "")

def a_init_admin():
    h = {"X-Setup-Token": E.get("SETUP_TOKEN", "")} if E.get("SETUP_TOKEN") else {}
    try: http("POST", P + "/api/users/admin/init", {"Username": E["ADMIN_USER"], "Password": E["ADMIN_PASS"]}, h, timeout=30)
    except urllib.error.HTTPError as e: fail(f"Admin account not created ({e.code}): {errtext(e)}")
    ok("Admin account created")

def a_make_token():
    try:
        jwt = http("POST", P + "/api/auth", {"username": E["P_USER"], "password": E["P_PASS"]}, timeout=30)["jwt"]
    except urllib.error.HTTPError as e: fail(f"Portainer login failed ({e.code})")
    h = {"Authorization": "Bearer " + jwt}
    me = http("GET", P + "/api/users/me", headers=h, timeout=30)
    desc = f"portainer-setup {datetime.date.today()}"
    r = http("POST", P + f"/api/users/{me['Id']}/tokens", {"password": E["P_PASS"], "description": desc}, h, timeout=30)
    print(r["rawAPIKey"])

def a_check_token():
    try: api("GET", "/users/me"); return
    except Exception: sys.exit(3)

def a_check_pat():
    gh_tree(); ok(f"PAT works ({REPO})")

def a_update_source():
    # Portainer keeps its own copy of the PAT on the git source shared by the stacks
    url = repo_url().lower()
    src = api("GET", "/gitops/sources?type=git")
    src = src.get("items", src) if isinstance(src, dict) else src
    hit = [s for s in src if ((s.get("git") or {}).get("URL", "").rstrip("/").removesuffix(".git").lower() == url)]
    for s in hit:
        api("PUT", f"/gitops/sources/{s['id']}", {"authentication": {"username": REPO.split("/")[0], "password": E["GH_PAT"]}})
    n = sum(1 for s in stacks() if (s.get("GitConfig") or {}).get("URL", "").rstrip("/").removesuffix(".git").lower() == url)
    if hit: ok(f"Portainer updated ({n} stacks)")

# ---- add stacks ----
VAR_RE = re.compile(r"(?<!\$)\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?-([^}]*))?\}")   # $${X} is an escaped $, not a variable
def compose_vars(text):
    """[(name, compose_default, hint)] in order of first appearance."""
    out, seen = [], set()
    for line in text.splitlines():
        code, _, comment = line.partition("#")
        m_h = re.search(r"#\s*hint:\s*(.+)$", line)
        hint = m_h.group(1).strip() if m_h else ""
        for m in VAR_RE.finditer(code):
            if m.group(1) in seen: continue
            seen.add(m.group(1)); out.append((m.group(1), m.group(2), hint))
    return out
def label(name, cdef, hint):
    parts = []
    is_random = hint.lower().split(";")[-1].strip() == "random" or hint.lower() == "random"
    eg = [p.strip() for p in hint.split(";") if p.strip() and p.strip().lower() != "random"]
    parts += eg
    if is_random: parts.append("default: random")
    elif cdef not in (None, ""): parts.append(f"default: {cdef}")
    return (f"{name} ({', '.join(parts)})" if parts else name), is_random
def rand_secret(n=32):
    a = string.ascii_letters + string.digits
    return "".join(secrets.choice(a) for _ in range(n))
def parse_pick(text, n):
    text = (text or "").strip().lower()
    if text == "all": return list(range(1, n + 1))
    out = set()
    for tok in re.split(r"[\s,]+", text):
        if not tok: continue
        m = re.fullmatch(r"(\d+)(?:-(\d+))?", tok)
        if not m: return None
        a, b = int(m.group(1)), int(m.group(2) or m.group(1))
        if a < 1 or b > n or a > b: return None
        out.update(range(a, b + 1))
    return sorted(out) or None
def pick_apps(free):
    print("Apps:")
    w = len(str(len(free))); cols = 3; rows = -(-len(free) // cols)
    for r in range(rows):
        print("".join(f"  {i+1:>{w}}) {free[i]:<18}" for i in range(r, len(free), rows)))
    while True:
        ans = tty_in("Select (e.g. 1 3 5, 2-4, all): ")
        if ans is None: fail("No selection received; pass names instead, e.g. add jellyfin vaultwarden")
        if ans.strip() in ("", "0"): return []
        idx = parse_pick(ans, len(free))
        if idx: return [free[i - 1] for i in idx]
        print(f"  Use numbers 1-{len(free)}, ranges like 2-4, or all.")

def a_add(names):
    eid = endpoint_id()
    deployed = {s["Name"].lower() for s in stacks()}
    tree = gh_tree()
    avail = sorted(f[:-len("-compose.yml")] for f in tree if f.endswith("-compose.yml") and "/" not in f)
    if not names:
        free = [a for a in avail if a not in deployed]
        if not free: ok("Every app in the repo is already deployed"); return
        names = pick_apps(free)
        if not names: info("Nothing selected"); return
    names = [n.strip().lower() for n in names]
    bad = [n for n in names if n not in avail]
    if bad: fail(f"Not in repo: {', '.join(bad)}. Available: {', '.join(avail)}")
    for n in [n for n in names if n in deployed]: info(f"{n} already deployed, skipped")
    names = [n for n in names if n not in deployed]
    plan, generated = [], []
    for n in names:   # collect every value before creating anything
        vars_ = compose_vars(gh_get(f"{n}-compose.yml").decode())
        env = []
        if vars_:
            print(f"{n} (Enter = default):")
            for name, cdef, hint in vars_:
                lab, is_random = label(name, cdef, hint)
                val = E.get(name)
                if val is None:
                    val = tty_in(f"  {lab} = ", secret=bool(re.search(r"PASS|SECRET|TOKEN|KEY", name)) and not is_random)
                    if val is None: fail(f"No terminal to ask for {name}; pass it as a variable, e.g. {name}=...")
                if val == "":
                    if is_random: val = rand_secret(); generated.append((n, name, val))
                    elif cdef not in (None, ""): continue           # compose default applies
                    else: warn(f"{n}: {name} left empty")
                env.append({"name": name, "value": val})
        plan.append((n, env))
    failed = []
    for n, env in plan:
        body = {"name": n, "repositoryURL": repo_url(), "repositoryReferenceName": f"refs/heads/{BRANCH}",
                "composeFile": f"{n}-compose.yml", "env": env, "tlsskipVerify": False,
                "repositoryAuthentication": True, "repositoryUsername": REPO.split("/")[0], "repositoryPassword": E["GH_PAT"]}
        try: api("POST", f"/stacks/create/standalone/repository?endpointId={eid}", body); ok(n)
        except urllib.error.HTTPError as e: failed.append(n); warn(f"{n} FAILED {e.code}: {errtext(e)}")
    if generated:
        print("Generated values (also in Portainer → stack → Environment variables):")
        for n, k, v in generated: print(f"  {n}: {k} = {v}")
    if failed: fail(f"{len(failed)} app(s) failed: {', '.join(failed)}")

# ---- backup ----
def fingerprint():
    keep = lambda s: {k: s.get(k) for k in ("Name", "Env", "Type")} | {"git": {k: (s.get("GitConfig") or {}).get(k) for k in ("URL", "ConfigFilePath", "ReferenceName")}}
    st = sorted((keep(s) for s in stacks()), key=lambda x: x["Name"])
    users = sorted((u.get("Username"), u.get("Role")) for u in api("GET", "/users"))
    return hashlib.sha256(json.dumps([st, users], sort_keys=True).encode()).hexdigest()

def state_path(): return os.path.join(E.get("STATE_DIR", "/var/lib/portainer-setup"), "state.json")
def state():
    try: return json.load(open(state_path()))
    except Exception: return {}
def save_state(**kw):
    s = state(); s.update(kw); os.makedirs(os.path.dirname(state_path()), exist_ok=True)
    json.dump(s, open(state_path(), "w"))

def do_backup(force):
    fp = fingerprint()
    try: meta = json.loads(gh_get(BMETA).decode())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403): fail(f"GitHub PAT cannot read {REPO} ({e.code})")
        meta = {}
    if not force and meta.get("fingerprint") == fp:
        return "unchanged", meta.get("created")
    data = api("POST", "/backup", {"Password": E["BACKUP_PASSWORD"]}, raw=True)
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    ver = http("GET", P + "/api/system/status", timeout=10)["Version"]
    gh_put(BFILE, data, f"Portainer backup {now}")
    gh_put(BMETA, json.dumps({"created": now, "portainer_version": ver, "stacks": len(stacks()), "fingerprint": fp}, indent=1).encode(),
           f"Portainer backup {now} (meta)")
    return "pushed", now

def a_backup(force=False):
    res, when = do_backup(force)
    if res == "pushed": ok(f"Backup pushed to {REPO}/{os.path.dirname(BFILE)}")
    else: ok(f"No changes since last backup ({when})")
    save_state(last_run=time.time(), last_result="ok", last_change=when)

def a_backup_run():
    host = os.uname().nodename
    try:
        res, when = do_backup(False)
        save_state(last_run=time.time(), last_result="ok", last_change=when)
        print(f"backup {res} ({when})")
        st = state()
        if time.time() - st.get("last_ok_mail", 0) > 7 * 86400 - 3600:
            if send_mail(f"[{host}] Backups OK", f"Portainer backup is working.\nLast change backed up: {when}\nRepo: {REPO}/{BFILE}\n"):
                save_state(last_ok_mail=time.time())
    except Exception as e:
        msg = str(e) if isinstance(e, Fail) else f"{type(e).__name__}: {e}"
        save_state(last_run=time.time(), last_result="failed: " + msg)
        hint = ""
        if "PAT" in msg: hint = "\nFix: run portainer-setup → Settings → Change GitHub PAT"
        elif "token" in msg.lower() or "401" in msg: hint = "\nFix: run portainer-setup (it will ask you to log in to Portainer once)"
        try: send_mail(f"[{host}] Portainer backup FAILED", f"{msg}{hint}\n")
        except Exception as m: print(f"alert email failed too: {m}", file=sys.stderr)
        fail(msg)

def a_backup_status():
    st = state()
    if not st.get("last_run"): print("never run"); return
    t = datetime.datetime.fromtimestamp(st["last_run"]).strftime("%Y-%m-%d %H:%M")
    r = st.get("last_result", "?")
    print(f"last: {t} {'OK' if r == 'ok' else 'FAILED'}")

# ---- restore ----
def a_restore_fetch(path):
    try: meta = json.loads(gh_get(BMETA).decode())
    except urllib.error.HTTPError as e:
        if e.code == 404: fail(f"No backup found in {REPO}/{os.path.dirname(BFILE)}")
        raise
    data = gh_get(BFILE)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f: f.write(data)
    cur = wait_up()
    print(json.dumps({"created": meta.get("created"), "version": meta.get("portainer_version"), "current": cur}))

def a_restore_post(path):
    bnd = "----portainersetup" + secrets.token_hex(8)
    blob = open(path, "rb").read()
    body = (f"--{bnd}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"portainer-backup.tar.gz\"\r\n"
            f"Content-Type: application/gzip\r\n\r\n").encode() + blob + \
           (f"\r\n--{bnd}\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\n{E.get('BACKUP_PASSWORD','')}\r\n--{bnd}--\r\n").encode()
    h = {"Content-Type": f"multipart/form-data; boundary={bnd}"}
    if E.get("SETUP_TOKEN"): h["X-Setup-Token"] = E["SETUP_TOKEN"]
    try: http("POST", P + "/api/restore", headers=h, data=body, raw=True, timeout=300)
    except urllib.error.HTTPError as e:
        t = errtext(e)
        if "password" in t.lower() or "decrypt" in t.lower() or "gzip" in t.lower(): fail("Wrong backup password")
        fail(f"Restore failed ({e.code}): {t}")
    time.sleep(5); wait_up(180)   # Portainer restarts itself after a restore
    ok("Portainer restored")

def a_redeploy_all():
    eid = endpoint_id(); failed = []
    st = sorted(stacks(), key=lambda s: s["Name"])
    for s in st:
        try:
            if s.get("GitConfig"):
                api("PUT", f"/stacks/{s['Id']}/git/redeploy?endpointId={eid}", {"RepullImageAndRedeploy": False})
            else:
                try: api("POST", f"/stacks/{s['Id']}/start?endpointId={eid}")
                except urllib.error.HTTPError as e:
                    if e.code != 400: raise          # 400 = already running
            ok(s["Name"])
        except urllib.error.HTTPError as e:
            failed.append(s["Name"]); warn(f"{s['Name']} FAILED {e.code}: {errtext(e)}")
    if failed: fail(f"{len(failed)} stack(s) failed: {', '.join(failed)}. Retry them in Portainer (Pull and redeploy).")

def a_mail_test():
    host = os.uname().nodename
    try:
        if not send_mail(f"[{host}] Test alert", "Alert email is working.\n"): fail("Email settings incomplete")
    except Exception as e:
        if isinstance(e, Fail): raise
        fail(f"Email not sent: {e}")
    ok("Test email sent. Check your inbox.")

act, args = sys.argv[1], sys.argv[2:]
try:
    {"wait-up": a_wait_up, "setup-token": a_setup_token, "init-admin": a_init_admin, "make-token": a_make_token,
     "check-token": a_check_token, "check-pat": a_check_pat, "update-source": a_update_source,
     "add": lambda: a_add(args), "backup": lambda: a_backup("--force" in args), "backup-run": a_backup_run,
     "backup-status": a_backup_status, "restore-fetch": lambda: a_restore_fetch(args[0]),
     "restore-post": lambda: a_restore_post(args[0]), "redeploy-all": a_redeploy_all, "mail-test": a_mail_test}[act]()
except Fail as e:
    c(31, "[FAIL]", str(e), True); sys.exit(1)
except urllib.error.URLError as e:
    c(31, "[FAIL]", f"Network error: {getattr(e, 'reason', e)}", True); sys.exit(1)
PY
  PORTAINER_URL="$PORTAINER_URL" GH_REPO="$GH_REPO" GH_BRANCH="$GH_BRANCH" BACKUP_FILE="$BACKUP_FILE" \
    STATE_DIR="$STATE_DIR" NAME="$NAME" python3 "$py" "$@" || rc=$?
  rm -f "$py"
  return "$rc"
}

# --- Portainer container -----------------------------------------------------
start_portainer(){
  local sock_gid; sock_gid="$(stat -c '%g' /var/run/docker.sock)"
  docker volume inspect portainer_data >/dev/null 2>&1 || docker volume create portainer_data >/dev/null
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker run -d --name "${NAME}" \
    --pull=always --restart=always \
    --security-opt apparmor=unconfined \
    --security-opt seccomp=unconfined \
    -p ${PORT_HTTPS}:${PORT_HTTPS} \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    $( [[ -n "${HOST_BIND}" ]] && echo "-v ${HOST_BIND}:/mnt/sec/apps" ) \
    --group-add "${sock_gid}" \
    "${IMAGE}" \
    -H unix:///var/run/docker.sock >/dev/null
  engine wait-up >/dev/null || fail "Container failed to start"
  local ip; ip=$(hostname -I | awk '{print $1}')
  ok "Portainer is up at https://${ip}:${PORT_HTTPS}"
}

install_self(){ # keep a local copy so the nightly job never depends on a fresh download
  local tmp; tmp="$(mktemp)"
  if command -v curl >/dev/null; then curl -fsSL "$SELF_URL?$(date +%s)" -o "$tmp"; else wget -qO "$tmp" "$SELF_URL?$(date +%s)"; fi \
    && bash -n "$tmp" && install -m 700 "$tmp" "$SELF_PATH" || warn "Could not refresh $SELF_PATH"
  rm -f "$tmp"
}

# --- Credentials -----------------------------------------------------------------
need_pat(){ # ensure a working PAT is stored; re-ask if the stored one stopped working
  if [[ -n "${GH_PAT:-}" ]] && engine check-pat >/dev/null 2>&1; then return; fi
  [[ -n "${GH_PAT:-}" ]] && warn "Stored GitHub PAT no longer works"
  have_tty || fail "GitHub PAT missing or invalid; run portainer-setup interactively"
  while true; do
    GH_PAT="$(ask_secret "GitHub PAT for ${GH_REPO} (Contents: Read and write)")"; export GH_PAT
    engine check-pat && break
  done
  write_env "$CONF_DIR/github.env" "GH_REPO=$GH_REPO" "GH_PAT=$GH_PAT"
  if [[ -n "${PORTAINER_TOKEN:-}" ]] && engine check-token 2>/dev/null; then engine update-source || true; fi
}

need_token(){ # ensure a working Portainer API token is stored
  if [[ -n "${PORTAINER_TOKEN:-}" ]] && engine check-token 2>/dev/null; then return; fi
  have_tty || fail "Portainer API token missing or invalid; run portainer-setup interactively"
  local u p t
  while true; do
    u="$(ask 'Portainer username' admin)"; p="$(ask_secret 'Portainer password')"
    t="$(P_USER="$u" P_PASS="$p" engine make-token)" && break
  done
  PORTAINER_TOKEN="$t"; export PORTAINER_TOKEN
  write_env "$CONF_DIR/portainer.env" "PORTAINER_TOKEN=$PORTAINER_TOKEN"
}

need_mail(){ # alert email settings, shared with backup-setup.sh
  [[ -n "${SMTP_HOST:-}" && -n "${SMTP_PASSWORD:-}" && -n "${ALERT_TO:-}" ]] && return
  setup_mail
}
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

save_backup_env(){ write_env "$CONF_DIR/backup.env" "BACKUP_PASSWORD=${BACKUP_PASSWORD:-}" "BACKUP_TIME=$BACKUP_TIME"; }

need_backup_password(){
  [[ -n "${BACKUP_PASSWORD:-}" ]] && return
  BACKUP_PASSWORD="$(ask_new_secret 'Backup password')"; export BACKUP_PASSWORD
  save_backup_env
}

# --- Nightly backup timer ------------------------------------------------------
timer_enable(){
  install_self
  cat >$UNIT_DIR/$TIMER.service <<EOF
[Unit]
Description=Portainer backup to GitHub
After=docker.service network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF_PATH backup-run
EOF
  cat >$UNIT_DIR/$TIMER.timer <<EOF
[Unit]
Description=Nightly Portainer backup
[Timer]
OnCalendar=*-*-* ${BACKUP_TIME}:00
Persistent=true
RandomizedDelaySec=5m
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$TIMER.timer" >/dev/null 2>&1
  ok "Nightly at ${BACKUP_TIME}, email on failure only"
}
timer_disable(){
  systemctl disable --now "$TIMER.timer" >/dev/null 2>&1 || true
  rm -f $UNIT_DIR/$TIMER.service $UNIT_DIR/$TIMER.timer
  systemctl daemon-reload
  ok "Nightly backup turned off"
}

turn_on_backup(){
  need_token; need_pat; need_backup_password; need_mail
  engine backup --force || fail "Test backup failed; nightly backup not turned on"
  timer_enable
}

# --- Flows ----------------------------------------------------------------------
apps_dir_empty(){ [[ -n "$HOST_BIND" && -d "$HOST_BIND" && -z "$(ls -A "$HOST_BIND" 2>/dev/null)" ]]; }

flow_restore(){ # Portainer must be freshly started (no admin yet)
  if apps_dir_empty; then
    warn "${HOST_BIND} is empty"
    if yesno "Restore app data first?" y; then
      info "Run backup-setup.sh → Restore, then run this again."; exit 0
    fi
  fi
  need_pat
  local f meta created ver cur pw tok
  f="$(mktemp)"
  meta="$(engine restore-fetch "$f")" || { rm -f "$f"; fail "Could not fetch backup"; }
  created="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["created"])' "$meta")"
  ver="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("version") or "?")' "$meta")"
  cur="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["current"])' "$meta")"
  info "Latest backup: ${created}"
  if [[ "$ver" != "?" ]] && [[ "$(printf '%s\n%s\n' "$ver" "$cur" | sort -V | head -1)" != "$ver" ]]; then
    warn "Backup is from Portainer ${ver}; this is ${cur} (older). Run Update first if restore fails."
  fi
  while true; do
    pw="$(ask_secret 'Backup password')"
    engine wait-up >/dev/null; tok="$(engine setup-token)"
    if BACKUP_PASSWORD="$pw" SETUP_TOKEN="$tok" engine restore-post "$f"; then break; fi
    yesno "Try again?" y || { rm -f "$f"; fail "Restore cancelled"; }
  done
  rm -f "$f"
  BACKUP_PASSWORD="$pw"; export BACKUP_PASSWORD
  save_backup_env
  info "Log in with your Portainer account from the backup"
  PORTAINER_TOKEN=""; need_token
  engine update-source >/dev/null || true      # stacks pull with the current PAT
  engine redeploy-all || true
  if yesno "Turn on nightly backup?" y; then need_mail; timer_enable; fi
  ok "Done. Log in with your account from the backup."
}

flow_fresh(){
  local u p tok
  u="$(ask 'Admin username' admin)"
  p="$(ask_new_secret 'Admin password (min 12 chars)' 12)"
  engine wait-up >/dev/null; tok="$(engine setup-token)"
  ADMIN_USER="$u" ADMIN_PASS="$p" SETUP_TOKEN="$tok" engine init-admin || fail "Admin account not created"
  PORTAINER_TOKEN="$(P_USER="$u" P_PASS="$p" engine make-token)" || fail "Could not create API token"
  export PORTAINER_TOKEN; write_env "$CONF_DIR/portainer.env" "PORTAINER_TOKEN=$PORTAINER_TOKEN"
  need_pat
  engine add || true
  yesno "Turn on nightly backup?" y && turn_on_backup
}

do_install(){
  start_portainer
  have_tty || { info "Finish setup by running portainer-setup in a terminal"; return; }
  echo "Setup options:"
  echo "1) Restore from backup"
  echo "2) Start fresh"
  echo "0) Skip"
  case "$(asknum 'Enter choice' 1 2 1)" in
    1) flow_restore ;;
    2) flow_fresh ;;
    0) info "Open https://<host-ip>:${PORT_HTTPS} to finish setup in the browser" ;;
  esac
}

do_update(){
  info "Pulling ${IMAGE}…"
  docker pull "${IMAGE}" >/dev/null
  start_portainer
  [[ -f "$SELF_PATH" ]] && install_self && ok "Script refreshed"
  return 0
}

menu_backup(){
  local st; st="$(engine backup-status 2>/dev/null || echo '?')"
  if timer_on; then echo "Nightly backup: ON at ${BACKUP_TIME} (${st})"; else echo "Nightly backup: OFF"; fi
  echo "1) Back up now"
  if timer_on; then echo "2) Turn off nightly backup"; else echo "2) Turn on nightly backup"; fi
  echo "0) Back"
  case "$(asknum 'Enter choice' 1 2 "$(timer_on && echo 1 || echo 2)")" in
    1) need_token; need_pat; need_backup_password; engine backup ;;
    2) if timer_on; then timer_disable; else turn_on_backup; fi ;;
    0) return ;;
  esac
}

do_restore_installed(){
  warn "This replaces Portainer's settings and stacks with the latest backup."
  yesno "Continue?" n || { info "Cancelled."; return; }
  if timer_on && [[ -n "${BACKUP_PASSWORD:-}" ]]; then
    info "Saving current state first…"; engine backup || warn "Pre-restore backup failed"
  fi
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm portainer_data >/dev/null 2>&1 || true
  start_portainer
  flow_restore
}

menu_settings(){
  echo "Settings:"
  echo "1) Change GitHub PAT"
  echo "2) Change backup password"
  echo "3) Change backup time"
  echo "4) Reset Portainer admin password"
  echo "5) Change alert email"
  echo "0) Back"
  case "$(asknum 'Enter choice' 1 5 1)" in
    1) local old="${GH_PAT:-}"
       while true; do
         GH_PAT="$(ask_secret "GitHub PAT for ${GH_REPO} (Contents: Read and write)")"; export GH_PAT
         engine check-pat && break
       done
       write_env "$CONF_DIR/github.env" "GH_REPO=$GH_REPO" "GH_PAT=$GH_PAT"; ok "Saved for nightly backup"
       need_token; engine update-source
       [[ -n "$old" && "$old" != "$GH_PAT" ]] && info "Delete the old PAT on GitHub"
       return 0 ;;
    2) BACKUP_PASSWORD="$(ask_new_secret 'New backup password')"; export BACKUP_PASSWORD
       save_backup_env
       need_token; need_pat; engine backup --force
       info "Older backups still need the old password" ;;
    3) local t tz; tz="$(date +%Z)"
       while true; do
         t="$(ask "Backup time, 24h server time ${tz}" "$BACKUP_TIME")"
         [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] && break
         echo "Use HH:MM, e.g. 02:15" >/dev/tty
       done
       BACKUP_TIME="$t"; save_backup_env
       if timer_on; then timer_enable; else ok "Saved. Turn on nightly backup under Backup."; fi ;;
    4) yesno "Reset the original admin account's password?" n || return 0
       docker stop "$NAME" >/dev/null
       docker run --rm -v portainer_data:/data portainer/helper-reset-password 2>&1 | sed -n 's/.*\(Password succes.*\|Use the following.*\)/\1/p'
       docker start "$NAME" >/dev/null; engine wait-up >/dev/null
       ok "Log in with the password above, then change it in Portainer (My account)" ;;
    5) setup_mail ;;
    0) return ;;
  esac
}

do_uninstall(){
  if have_tty; then yesno "Remove Portainer, its settings volume and nightly backup? (stacks keep running; GitHub backups are kept)" n || { info "Cancelled."; return; }
  else [[ "${CONFIRM:-}" == yes ]] || fail "Run with CONFIRM=yes to uninstall without a terminal"; fi
  timer_on && timer_disable
  docker rm -f "${NAME}" >/dev/null 2>&1 || true
  docker volume rm portainer_data >/dev/null 2>&1 || true
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -i '^portainer/portainer-ce:' | xargs -r docker rmi -f >/dev/null 2>&1 || true
  rm -rf "$CONF_DIR" "$STATE_DIR" "$SELF_PATH"
  ok "Uninstalled Portainer (container, volume, images, stored PAT/token/password). Alert email settings kept: $MAIL_CONF"
}

usage(){
  cat <<'EOF'
Usage:
  portainer-setup.sh                   # interactive menu (CLI)
  portainer-setup.sh install           # install, then set up in the menu
  portainer-setup.sh update
  portainer-setup.sh backup            # back up to GitHub now
  portainer-setup.sh add [app ...]     # deploy apps from the docker repo
  portainer-setup.sh uninstall         # CONFIRM=yes when no terminal
  portainer-setup.sh backup-run        # nightly job (systemd timer)

Piped from wget (Webmin custom command) — keep the '--' placeholder:
  bash -c "$(wget -qLO- .../portainer-setup.sh?$(date +%s))" -- update
EOF
}

run_action(){
  case "$1" in
    install)    exists_container && { info "Portainer is already installed"; return; }; do_install ;;
    update)     exists_container || fail "Portainer is not installed (try: install)"; do_update ;;
    backup)     need_token; need_pat; need_backup_password; engine backup ;;
    backup-run) engine backup-run ;;
    add)        shift; need_token; need_pat; engine add "$@" ;;
    uninstall)  do_uninstall ;;
    help|-h|--help) usage ;;
    *) usage >&2; fail "Unknown action '$1' (try: install|update|backup|add|uninstall)" ;;
  esac
}

# Parse optional CLI args (works in Webmin).
# Under `bash -c "$(wget …)" update` the word lands in $0 rather than $1, so
# accept it from there too — but only when it names a known action.
args=("$@")
if [[ $# -eq 0 ]]; then
  case "$0" in
    install|update|backup|backup-run|add|uninstall|help|-h|--help) args=("$0") ;;
  esac
fi
if (( ${#args[@]} )); then run_action "${args[@]}"; exit 0; fi

if ! have_tty; then
  usage >&2
  fail "No terminal for the interactive menu — pass an action (e.g. update)."
fi

if exists_container; then
  echo "Portainer installed:"
  echo "1) Update"
  echo "2) Backup"
  echo "3) Restore"
  echo "4) Add stack(s)"
  echo "5) Settings"
  echo "6) Uninstall"
  echo "0) Exit"
  case "$(asknum 'Enter choice' 1 6 1)" in
    0) exit 0 ;;
    1) do_update ;;
    2) menu_backup ;;
    3) do_restore_installed ;;
    4) need_token; need_pat; engine add ;;
    5) menu_settings ;;
    6) do_uninstall ;;
  esac
else
  echo "Portainer not installed:"
  echo "1) Install"
  echo "0) Exit"
  case "$(asknum 'Enter choice' 1 1 1)" in
    0) exit 0 ;;
    1) do_install ;;
  esac
fi
