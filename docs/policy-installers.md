# Installer Script Policy

Conventions for every `*-setup.sh` under `apps/installers/`. This is the single
source of truth for **how installer scripts are written** — when creating or
updating one (human or LLM), follow this so all scripts stay consistent.

We deliberately do **not** use a shared *sourced* library (e.g. a runtime
`ui.sh`): every script must be fully standalone. Instead, the shared UI block is
inlined into each script between markers and kept in sync from a single source by
a generator — see §5. So: standalone at runtime, single-edit at author time.

---

## 1. Golden rules

1. **Standalone & self-contained.** No sourcing of shared files. A script must
   run on its own via the one-liner:
   `bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/<name>-setup.sh?$(date +%s))"`
2. **Always-latest.** Fetches use `?$(date +%s)` to bust caches and pull `main`.
3. **Idempotent.** Re-running is safe: detect what's already done and skip it.
4. **Non-interactive capable.** Must work headless (piped from `wget`), reading
   any prompts from `/dev/tty`, and support an unattended path.
5. **Root required.** Check for root and exit clearly if missing.

## 2. Naming

- Installers: `apps/installers/<name>-setup.sh` (e.g. `docker-setup.sh`).
- An orchestrator step named `foo` resolves to `foo-setup.sh`, so the name *is*
  the contract — keep it lowercase, hyphenated.

## 3. File header (required)

```bash
#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/<name>-setup.sh?$(date +%s))"
# Purpose: <one line: what this installs/does, and target OS if relevant>
# =============================================================================
```

## 4. Safety preamble (required)

```bash
set -euo pipefail
```
Then the UI block (§5), then the root check (§6).

## 5. Canonical UI block (managed by sync-ui.sh)

Standard output style across all scripts: fixed-width bracket labels, colored by
severity, message text left uncolored. The four labels are each **6 columns**
(`[ OK ]`, `[INFO]`, `[WARN]`, `[FAIL]`), so message text always starts at the
same column — no jagged alignment in any terminal.

Paste this block **wrapped in the markers** shown. The region between the markers
is managed by `scripts/sync-ui.sh`, which copies the canonical copy from
`apps/installers/.ui-block.sh` into every script's marked region. So a future
restyle is a single edit (`.ui-block.sh`) + `scripts/sync-ui.sh` — do not edit
the block in place. Keep per-script extras (e.g. back-compat aliases) *outside*
the markers so the managed region stays byte-identical across files.

```bash
# >>> ui-block (managed by scripts/sync-ui.sh — do not edit here) >>>
# Colour is decided once: on if stdout is a real terminal, OR if a parent
# orchestrator forces it (FORCE_COLOR=1) so colour survives a tee pipe.
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
```

Verify every script's region matches the canonical block with
`scripts/sync-ui.sh --check` (use it in CI/pre-commit to catch drift).

Colors: `[ OK ]` green · `[INFO]` cyan · `[WARN]` yellow · `[FAIL]` red.

Multi-line / continuation text indents to the message column (8 spaces):

```
[ OK ] Kasm   https://192.168.1.50:443
       user: admin@kasm.local
```

Section banners (for multi-step scripts) use this form:

```bash
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  STEP 3/6: Docker"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
```

## 6. Root check (required)

```bash
[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."
```

## 7. Interactive prompts

Read from `/dev/tty` so input still works when the script is piped from `wget`:

```bash
if [[ -r /dev/tty ]]; then
    read -rp "Proceed? [y/N]: " ans </dev/tty || ans="n"
else
    ans="n"   # no tty (headless) → safe default
fi
```

Provide a non-interactive path: honor a `-y`/`--yes` flag and/or env vars so the
script can run unattended (required for orchestrated/headless use).

## Section headers

Within the body, label sections with a fixed-width header — `# --- Title ` padded
with dashes to **79 columns**:

```bash
# --- Variables ---------------------------------------------------------------
# --- Helpers -----------------------------------------------------------------
```

Keep the top `# ===…===` doc-block fence (the file header/usage block) and any
major multi-line `# ===` / `# TITLE` / `# ===` banners as-is. Use `# --- Title ---`
for the regular, single-line section dividers (not `# Title`, `# ==== Title ====`,
or unpadded variants).

## 8. Idempotency

Detect prior state and skip cleanly (exit 0, not an error). Examples:
`command -v docker`, `dpkg -l <pkg>`, a version check, `mountpoint -q`. A "nothing
to do" outcome is success.

## 9. Exit-code contract (orchestrator integration)

Scripts called by `vm-setup.sh` must use these exit codes:

| Code | Meaning |
|------|---------|
| `0`  | Success (including "already done / nothing to do"). |
| `10` | Success, **but a reboot is required** to take effect (e.g. a freshly installed kernel module). The orchestrator will reboot and resume. |
| other| Genuine failure (use `fail`). |

Never auto-reboot from inside an installer — report `10` and let the orchestrator
own the reboot/resume.

## 10. Host vs VM auto-detection (when applicable)

Scripts that do different things on the Proxmox host vs inside a VM detect with:

```bash
is_proxmox_host() { [[ -f /etc/pve/.version ]] || command -v pveversion &>/dev/null; }
```
Expose clear subcommands per side (see `gpu-setup.sh`, `virtiofs-setup.sh`).

## 11. Logging + colour (orchestrators that tee to a file)

When a script tees its whole run to a log (e.g. `vm-setup.sh`):

```bash
# Decide colour from the REAL terminal before redirecting, then force it on for
# children so colour survives the pipe; strip ANSI on the way to the log file so
# the log stays clean text.
[[ -t 1 ]] && export FORCE_COLOR=1
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1
```
Keep logs outside any state dir that gets cleaned up at the end of a run.

## 12. Minimal compliant skeleton

```bash
#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/installers/example-setup.sh?$(date +%s))"
# Purpose: Example installer (Ubuntu)
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

[[ $EUID -eq 0 ]] || fail "This script must be run as root (or via sudo)."

# --- Idempotency check -------------------------------------------------------
if command -v example >/dev/null 2>&1; then
    ok "example is already installed. Nothing to do."
    exit 0
fi

# --- Install -----------------------------------------------------------------
info "Installing example..."
# ... do the work; on failure call: fail "what went wrong"
ok "example installed."
```
