#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/stacks-setup.sh?$(date +%s))"
# Purpose: Backs up, restores and adds Portainer stacks deployed from the private docker repo
# =============================================================================
# Usage:
#   stacks-setup                         Interactive menu
#   stacks-setup list                    Show every stack and where it deploys from
#   stacks-setup backup                  Save all stack definitions (incl. env values) to BACKUP_DIR
#   stacks-setup restore                 Recreate missing stacks from the newest backup
#                                        (fresh install, no backup: pick apps from the repo)
#   stacks-setup add [app ...]           Deploy apps from the docker repo (no names: pick from a list)
#
# Credentials are asked for at run time and never written to disk:
#   - Portainer admin username + password (or PORTAINER_TOKEN, an access token)
#   - GitHub fine-grained token with Contents: Read-only on the docker repo (GH_PAT)
#
# Non-interactive (for Webmin custom commands), pass credentials as variables:
#   sudo PORTAINER_TOKEN=ptr_xxx GH_PAT=github_pat_xxx \
#     bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/stacks-setup.sh?$(date +%s))" -- restore
#
# Note: keep the `--` placeholder — bash assigns the first word after the
#       script body to $0, not $1, so without it the action is lost.
#
# Safety: restore and add never delete or overwrite a stack. They check the
#         GitHub token and every compose file first, and create nothing if a
#         check fails. Existing stacks with the same name are skipped.
# =============================================================================

set -euo pipefail

# --- Settings ----------------------------------------------------------------
PORTAINER_URL="${PORTAINER_URL:-https://127.0.0.1:9443}"
REPO_URL="${REPO_URL:-https://github.com/therepos/docker}"
REPO_REF="${REPO_REF:-refs/heads/main}"
GH_USER="${GH_USER:-therepos}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/sec/backup/portainer-stacks}"
KEEP_BACKUPS="${KEEP_BACKUPS:-10}"   # newest N backup files kept

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

ask(){ # ask "prompt" [secret] -> echoes answer
  local p="$1" secret="${2:-}" in=""
  have_tty || fail "No terminal to ask for: $p (pass it as a variable instead)"
  if [[ -n "$secret" ]]; then
    read -rsp "$p: " in </dev/tty; echo >/dev/tty
  else
    read -rp "$p: " in </dev/tty
  fi
  printf '%s' "$in"
}

# --- Prechecks ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
command -v python3 >/dev/null || fail "python3 not found"

# --- Credentials -------------------------------------------------------------
need_portainer(){
  [[ -n "${PORTAINER_TOKEN:-}" ]] && return
  [[ -n "${PORTAINER_USER:-}" ]] || PORTAINER_USER="$(ask 'Portainer username')"
  [[ -n "${PORTAINER_PASS:-}" ]] || PORTAINER_PASS="$(ask 'Portainer password' secret)"
  export PORTAINER_USER PORTAINER_PASS
}
need_github(){
  [[ -n "${GH_PAT:-}" ]] || GH_PAT="$(ask "GitHub token for ${REPO_URL#https://github.com/} (Contents: Read-only)" secret)"
  [[ -n "$GH_PAT" ]] || fail "A GitHub token is required"
  export GH_PAT
}

# --- Engine (Portainer + GitHub API calls) -----------------------------------
run_engine(){ # run_engine <action> [arg]
  local py rc=0; py="$(mktemp)"
  cat >"$py" <<'PY'
import base64, glob, json, os, re, ssl, sys, time, urllib.error, urllib.request

P      = os.environ["PORTAINER_URL"].rstrip("/")
REPO   = os.environ["REPO_URL"].rstrip("/")
REF    = os.environ["REPO_REF"]
GHUSER = os.environ["GH_USER"]
BDIR   = os.environ["BACKUP_DIR"]
KEEP   = int(os.environ.get("KEEP_BACKUPS", "10"))
GHAPI  = os.environ.get("GH_API", "https://api.github.com").rstrip("/")
C = {k: (v if (os.environ.get("FORCE_COLOR") or sys.stdout.isatty()) else "")
     for k, v in dict(K="\033[1;32m", I="\033[1;36m", W="\033[1;33m", E="\033[1;31m", Z="\033[0m").items()}
def ok(m):   print(f"{C['K']}[ OK ]{C['Z']} {m}", flush=True)
def info(m): print(f"{C['I']}[INFO]{C['Z']} {m}", flush=True)
def warn(m): print(f"{C['W']}[WARN]{C['Z']} {m}", file=sys.stderr, flush=True)
def fail(m): print(f"{C['E']}[FAIL]{C['Z']} {m}", file=sys.stderr, flush=True); sys.exit(1)

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
HDR = {"Content-Type": "application/json"}

def http(method, url, body=None, headers=None, ctx=None, timeout=600):
    req = urllib.request.Request(url, method=method, headers=headers or {},
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        d = r.read()
        return json.loads(d) if d else None

def api(method, path, body=None):
    return http(method, P + "/api" + path, body, HDR, CTX)

def err_text(e):
    try: return e.read().decode()[:300]
    except Exception: return str(e)

# --- Portainer login + environment ---------------------------------------------
def login():
    if os.environ.get("PORTAINER_TOKEN"):
        HDR["X-API-Key"] = os.environ["PORTAINER_TOKEN"]
    else:
        try:
            r = http("POST", P + "/api/auth", {"username": os.environ["PORTAINER_USER"],
                     "password": os.environ["PORTAINER_PASS"]}, {"Content-Type": "application/json"}, CTX, 30)
        except urllib.error.HTTPError as e:
            fail(f"Portainer login failed ({e.code}) — check username/password")
        except urllib.error.URLError as e:
            fail(f"Cannot reach Portainer at {P} ({e.reason})")
        HDR["Authorization"] = "Bearer " + r["jwt"]
    try:
        eps = api("GET", "/endpoints")
    except urllib.error.HTTPError as e:
        fail(f"Portainer rejected the credentials ({e.code})")
    except urllib.error.URLError as e:
        fail(f"Cannot reach Portainer at {P} ({e.reason})")
    if os.environ.get("ENDPOINT_ID"):
        eid = int(os.environ["ENDPOINT_ID"])
    elif len(eps) == 1:
        eid = eps[0]["Id"]
    else:
        local = [e for e in eps if str(e.get("URL", "")).startswith("unix://")]
        if len(local) != 1:
            fail("Several Portainer environments found; set ENDPOINT_ID to one of: "
                 + ", ".join(f"{e['Id']}={e['Name']}" for e in eps))
        eid = local[0]["Id"]
    return eid

# --- GitHub: validate token and list repo files ---------------------------------
def repo_owner_name():
    m = re.match(r"https://github\.com/([^/]+)/([^/.]+)", REPO)
    if not m: fail(f"REPO_URL must be a github.com repo, got {REPO}")
    return m.group(1), m.group(2)

def repo_files():
    owner, name = repo_owner_name()
    branch = REF.split("/")[-1]
    h = {"Authorization": "Bearer " + os.environ["GH_PAT"], "Accept": "application/vnd.github+json",
         "User-Agent": "stacks-setup"}
    try:
        t = http("GET", f"{GHAPI}/repos/{owner}/{name}/git/trees/{branch}", headers=h, timeout=30)
    except urllib.error.HTTPError as e:
        fail(f"GitHub token cannot read {owner}/{name} ({e.code}). The token needs "
             f"Repository access: {owner}/{name}, Permissions: Contents = Read-only.")
    except urllib.error.URLError as e:
        fail(f"Cannot reach GitHub ({e.reason})")
    ok(f"GitHub token can read {owner}/{name}")
    return {x["path"] for x in t.get("tree", []) if x.get("type") == "blob"}, h

def repo_file_text(path, h):
    owner, name = repo_owner_name()
    hh = dict(h, Accept="application/vnd.github.raw")
    req = urllib.request.Request(f"{GHAPI}/repos/{owner}/{name}/contents/{path}?ref={REF.split('/')[-1]}", headers=hh)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()

def same_repo(url):
    return (url or "").rstrip("/").removesuffix(".git").lower() == REPO.lower()

# --- Create one stack -----------------------------------------------------------
def create_git_stack(eid, name, repo, ref, compose, env, auth):
    body = {"name": name, "repositoryURL": repo, "repositoryReferenceName": ref,
            "composeFile": compose, "env": env or [], "tlsskipVerify": False,
            "repositoryAuthentication": bool(auth)}
    if auth:
        body.update(repositoryUsername=GHUSER, repositoryPassword=os.environ["GH_PAT"])
    return api("POST", f"/stacks/create/standalone/repository?endpointId={eid}", body)

def create_string_stack(eid, name, content, env):
    body = {"name": name, "stackFileContent": content, "env": env or []}
    return api("POST", f"/stacks/create/standalone/string?endpointId={eid}", body)

# --- Actions ------------------------------------------------------------------------
def do_list():
    login()
    stacks = sorted(api("GET", "/stacks"), key=lambda s: s["Name"])
    if not stacks: info("No stacks."); return
    print(f"{'NAME':16} {'STATUS':8} {'ENV':>3}  SOURCE")
    for s in stacks:
        g = s.get("GitConfig") or {}
        src = f"{g.get('URL','')} :: {g.get('ConfigFilePath','')}" if g else "web editor / upload"
        st = {1: "running", 2: "stopped"}.get(s.get("Status"), "?")
        print(f"{s['Name']:16} {st:8} {len(s.get('Env') or []):>3}  {src}")

def do_backup():
    login()
    stacks = api("GET", "/stacks")
    out = []
    for s in sorted(stacks, key=lambda s: s["Name"]):
        g = s.get("GitConfig") or {}
        item = {"name": s["Name"], "env": s.get("Env") or []}
        if g:
            item.update(type="git", repo=g.get("URL"), ref=g.get("ReferenceName") or "refs/heads/main",
                        compose=g.get("ConfigFilePath"))
        else:
            try:
                item.update(type="file", content=api("GET", f"/stacks/{s['Id']}/file")["StackFileContent"])
            except urllib.error.HTTPError as e:
                warn(f"{s['Name']}: could not read compose file ({e.code}); backed up without it")
                item.update(type="file", content=None)
        out.append(item)
    os.makedirs(BDIR, exist_ok=True); os.chmod(BDIR, 0o700)
    path = os.path.join(BDIR, time.strftime("stacks-%Y%m%d-%H%M%S.json"))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"version": 1, "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "stacks": out}, f, indent=1)
    for old in sorted(glob.glob(os.path.join(BDIR, "stacks-*.json")))[:-KEEP]:
        os.remove(old)
    ok(f"Backed up {len(out)} stack(s) → {path}")
    warn("This file contains your stack passwords/secrets. It is readable by root only; keep it off Git.")

def do_restore():
    files = sorted(glob.glob(os.path.join(BDIR, "stacks-*.json")))
    if not files:
        warn(f"No backup found in {BDIR}.")
        ans = tty_in("Fresh install? Choose apps to deploy from the repo instead [Y/n]: ")
        if ans is None:
            fail("No terminal to choose apps. Run 'add <app> …' or put a backup in " + BDIR)
        if ans.strip().lower() in ("n", "no"):
            info("Cancelled."); return
        return do_add([])
    data = json.load(open(files[-1]))
    info(f"Using backup: {files[-1]} ({len(data['stacks'])} stacks)")
    eid = login()
    existing = {s["Name"].lower() for s in api("GET", "/stacks")}
    todo = [s for s in data["stacks"] if s["name"].lower() not in existing]
    for s in data["stacks"]:
        if s["name"].lower() in existing: info(f"[{s['name']}] already exists, skipped")
    if not todo: ok("Nothing to restore."); return

    # Pre-checks: nothing is created unless all of them pass.
    if any(s.get("type") == "git" and same_repo(s.get("repo")) for s in todo):
        files_in_repo, _ = repo_files()
        missing = [f"{s['name']} → {s['compose']}" for s in todo
                   if s.get("type") == "git" and same_repo(s.get("repo")) and s["compose"] not in files_in_repo]
        if missing: fail("Compose file(s) not found in repo, nothing created:\n  " + "\n  ".join(missing))
    nofile = [s["name"] for s in todo if s.get("type") == "file" and not s.get("content")]
    if nofile: fail("Backup has no compose content for: " + ", ".join(nofile) + ". Nothing created.")
    ok(f"Pre-checks passed; creating {len(todo)} stack(s)")

    failed = []
    for s in todo:
        info(f"[{s['name']}] creating …")
        try:
            if s.get("type") == "git":
                r = create_git_stack(eid, s["name"], s["repo"], s["ref"], s["compose"], s["env"], same_repo(s["repo"]))
            else:
                r = create_string_stack(eid, s["name"], s["content"], s["env"])
            ok(f"[{s['name']}] created (id {r['Id']})")
        except urllib.error.HTTPError as e:
            failed.append(s["name"]); warn(f"[{s['name']}] FAILED {e.code}: {err_text(e)}")
    if failed: fail(f"{len(failed)} stack(s) failed: {', '.join(failed)}. Re-run restore after fixing; done ones are skipped.")
    ok("Restore complete.")

TTY = None
def tty_in(prompt):
    """Read a line from the terminal (stdin is not usable under bash -c "$(wget …)")."""
    global TTY
    if TTY is None:
        try: TTY = open("/dev/tty")
        except OSError: return None
    print(prompt, end="", flush=True)
    line = TTY.readline()
    return None if line == "" else line.rstrip("\n")   # "" means end of input

def parse_pick(text, n):
    """'1 3 5', '1,3', '2-4', 'all' -> sorted 1-based indexes; None if invalid."""
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

def pick_apps(files_in_repo, deployed):
    apps = sorted(f[:-len("-compose.yml")] for f in files_in_repo if f.endswith("-compose.yml"))
    free = [a for a in apps if a not in deployed]
    if not free: ok("Every app in the repo is already deployed."); return []
    print(f"Apps in {REPO.removeprefix('https://github.com/')} not yet deployed:")
    w = len(str(len(free)))
    cols = 3; rows = -(-len(free) // cols)
    for r in range(rows):
        print("".join(f"  {i+1:>{w}}) {free[i]:<18}" for i in range(r, len(free), rows)))
    if deployed & set(apps):
        print(f"Already deployed (skipped): {', '.join(sorted(deployed & set(apps)))}")
    while True:
        ans = tty_in("Choose apps (e.g. 1 3 5, 2-4, all; 0 to cancel): ")
        if ans is None: fail("No selection received; pass names instead, e.g. add comfyui jellyfin")
        if ans.strip() == "0": info("Cancelled."); return []
        idx = parse_pick(ans, len(free))
        if idx: return [free[i - 1] for i in idx]
        print(f"  Not a valid choice. Use numbers 1-{len(free)}, ranges like 2-4, or all.")

def do_add(apps):
    eid = login()
    deployed = {s["Name"].lower() for s in api("GET", "/stacks")}
    files_in_repo, h = repo_files()
    if not apps:
        apps = pick_apps(files_in_repo, deployed)
        if not apps: return
    apps = [a.strip().lower() for a in apps]

    # Pre-checks for every chosen app before anything is created.
    bad = [a for a in apps if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", a)]
    if bad: fail(f"Invalid app name(s): {', '.join(bad)}")
    missing = [a for a in apps if f"{a}-compose.yml" not in files_in_repo]
    if missing:
        avail = sorted(f[:-len("-compose.yml")] for f in files_in_repo if f.endswith("-compose.yml"))
        fail(f"Not in repo: {', '.join(missing)}. Available: {', '.join(avail)}")
    for a in [a for a in apps if a in deployed]:
        info(f"[{a}] already exists, skipped (use Portainer's 'Pull and redeploy' to update it)")
    apps = [a for a in apps if a not in deployed]
    if not apps: ok("Nothing to add."); return

    # Collect ${VAR} values (no default in the compose) for all apps first.
    plan = []
    for a in apps:
        compose = f"{a}-compose.yml"
        text = repo_file_text(compose, h)
        needed = sorted({m.group(1) for m in re.finditer(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", text)})
        env = []
        if needed:
            info(f"[{a}] needs values for: {', '.join(needed)}")
            for var in needed:
                val = os.environ.get(var)
                if val is None:
                    val = tty_in(f"  {var} = ")
                    if val is None: fail(f"No terminal to ask for {var}; pass it as a variable, e.g. {var}=...")
                if not val: warn(f"[{a}] {var} left empty")
                env.append({"name": var, "value": val or ""})
        plan.append((a, compose, env))

    failed = []
    for a, compose, env in plan:
        info(f"[{a}] creating from {compose} …")
        try:
            r = create_git_stack(eid, a, REPO, REF, compose, env, True)
            ok(f"[{a}] created (id {r['Id']})")
        except urllib.error.HTTPError as e:
            failed.append(a); warn(f"[{a}] FAILED {e.code}: {err_text(e)}")
    if failed: fail(f"{len(failed)} app(s) failed: {', '.join(failed)}")
    ok(f"Added {len(plan)} stack(s).")
    warn("Run 'Backup stacks' so these are included in your next restore.")

action = sys.argv[1]
if   action == "list":    do_list()
elif action == "backup":  do_backup()
elif action == "restore": do_restore()
elif action == "add":     do_add(sys.argv[2:])
PY
  export PORTAINER_URL REPO_URL REPO_REF GH_USER BACKUP_DIR KEEP_BACKUPS
  python3 "$py" "$@" || rc=$?
  rm -f "$py"
  return "$rc"
}

act_list(){    need_portainer;              run_engine list; }
act_backup(){  need_portainer;              run_engine backup; }
act_restore(){ need_portainer; need_github; run_engine restore; }
act_add(){ need_portainer; need_github; run_engine add "$@"; }

usage(){
  cat <<'EOF'
Usage:
  stacks-setup.sh                      # interactive menu (CLI)
  stacks-setup.sh list                 # show stacks and their source
  stacks-setup.sh backup               # save stack definitions + env values
  stacks-setup.sh restore              # recreate missing stacks from newest backup
  stacks-setup.sh add [app ...]        # deploy apps from the repo (no names: pick from a list)
  stacks-setup.sh 1|2|3|4              # also accepted (menu numbers)

Piped from wget (Webmin custom command) — keep the '--' placeholder:
  sudo PORTAINER_TOKEN=... GH_PAT=... bash -c "$(wget -qLO- .../stacks-setup.sh?$(date +%s))" -- restore
EOF
}

run_action(){
  case "$1" in
    list|1)    act_list ;;
    backup|2)  act_backup ;;
    restore|3) act_restore ;;
    add|4)     shift; act_add "$@" ;;
    help|-h|--help) usage ;;
    *) usage >&2
       fail "Unknown action '$1' (try: list|backup|restore|add)" ;;
  esac
}

# Parse optional CLI args (works in Webmin).
# Under `bash -c "$(wget …)" restore` the word lands in $0 rather than $1, so
# accept it from there too — but only when it names a known action.
args=("$@")
if [[ $# -eq 0 ]]; then
  case "$0" in
    list|backup|restore|add|help|-h|--help|1|2|3|4) args=("$0") ;;
  esac
fi

if (( ${#args[@]} )); then
  run_action "${args[@]}"
  exit 0
fi

if ! have_tty; then
  usage >&2
  fail "No terminal for the interactive menu — pass an action (e.g. backup)."
fi

echo "Portainer stacks (${REPO_URL#https://github.com/}). What would you like to do?"
echo "1) List stacks"
echo "2) Backup stacks"
echo "3) Restore stack(s)"
echo "4) Add stack(s)"
echo "0) Exit"
choice="$(asknum 'Enter choice' 1 4 1)"
case "$choice" in
  0) ok "Bye."; exit 0 ;;
  *) run_action "$choice" ;;
esac
