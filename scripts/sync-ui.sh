#!/usr/bin/env bash
# Sync the canonical UI helper block into every installer's marked region.
# =============================================================================
# The installer scripts are standalone (the UI block lives physically inside
# each), but we still want a single place to edit the style. This is that place:
#
#   1. Edit the canonical block in apps/installers/.ui-block.sh
#   2. Run this script
#
# It replaces whatever sits between these markers in each *-setup.sh:
#       # >>> ui-block ... >>>
#       ...managed content...
#       # <<< ui-block <<<
# Files without the markers are left untouched. Run with --check to verify
# everything is in sync (non-zero exit if not) — handy for CI/pre-commit.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/apps/installers"
BLOCK="$DIR/.ui-block.sh"
[[ -f "$BLOCK" ]] || { echo "Missing canonical block: $BLOCK" >&2; exit 1; }

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

drift=0
changed=0
for f in "$DIR"/*.sh; do
    grep -q '# >>> ui-block' "$f" || continue
    awk -v blockfile="$BLOCK" '
        BEGIN { n=0; while ((getline l < blockfile) > 0) blk[n++]=l; close(blockfile) }
        /# >>> ui-block/ { print; for (i=0;i<n;i++) print blk[i]; skip=1; next }
        /# <<< ui-block/ { skip=0; print; next }
        !skip { print }
    ' "$f" > "$f.tmp"

    if cmp -s "$f" "$f.tmp"; then
        rm -f "$f.tmp"
    elif [[ $CHECK -eq 1 ]]; then
        rm -f "$f.tmp"
        echo "DRIFT: $(basename "$f")"
        drift=1
    else
        mv "$f.tmp" "$f"
        echo "updated: $(basename "$f")"
        changed=1
    fi
done

if [[ $CHECK -eq 1 ]]; then
    [[ $drift -eq 0 ]] && { echo "All in sync."; exit 0; } || { echo "Out of sync — run scripts/sync-ui.sh"; exit 1; }
fi
[[ $changed -eq 0 ]] && echo "All in sync."
exit 0
