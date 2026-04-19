#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/livephoto-convert.sh?$(date +%s))"
# =============================================================================
# PhotoPrism Live Photo → Still Converter
# =============================================================================
# What it does:
#   1. Scans your originals directory for live photo pairs (JPEG/HEIC + MOV/MP4)
#   2. Backs them all up into a timestamped zip archive
#   3. Converts HEIC stills to JPEG if needed (requires ImageMagick or ffmpeg)
#   4. Deletes the video sidecar files, leaving only the still images
#   5. Prints a summary report
#
# Requirements: zip, find (standard). For HEIC→JPEG: ImageMagick (convert) or ffmpeg
#
# Usage:
#   chmod +x convert_live_photos.sh
#   ./convert_live_photos.sh /path/to/photoprism/originals
#
#   Dry run (no changes made):
#   DRY_RUN=1 ./convert_live_photos.sh /path/to/photoprism/originals
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Args & config ─────────────────────────────────────────────────────────────
ORIGINALS_DIR="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "${ORIGINALS_DIR:-/tmp}")/live_photo_backups}"
CONVERT_HEIC="${CONVERT_HEIC:-1}"   # Set to 0 to skip HEIC→JPEG conversion

if [[ -z "$ORIGINALS_DIR" ]]; then
  error "Usage: $0 /path/to/photoprism/originals"
  error "       DRY_RUN=1 $0 /path/to/photoprism/originals"
  exit 1
fi

if [[ ! -d "$ORIGINALS_DIR" ]]; then
  error "Directory not found: $ORIGINALS_DIR"
  exit 1
fi

ORIGINALS_DIR="$(realpath "$ORIGINALS_DIR")"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ZIP="${BACKUP_DIR}/live_photos_backup_${TIMESTAMP}.zip"

echo -e "\n${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  PhotoPrism Live Photo Converter${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "  Originals : ${ORIGINALS_DIR}"
echo -e "  Backup zip: ${BACKUP_ZIP}"
echo -e "  Dry run   : $([ "$DRY_RUN" = "1" ] && echo 'YES — no changes will be made' || echo 'NO — files will be modified')"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}\n"

if [[ "$DRY_RUN" = "1" ]]; then
  warn "DRY RUN MODE — listing actions only, nothing will be changed.\n"
fi

# ── Check dependencies ────────────────────────────────────────────────────────
check_cmd() {
  if command -v "$1" &>/dev/null; then
    success "Found: $1"
    return 0
  else
    warn "Not found: $1"
    return 1
  fi
}

info "Checking dependencies..."
HAS_ZIP=0;     check_cmd zip     && HAS_ZIP=1
HAS_CONVERT=0; check_cmd convert && HAS_CONVERT=1   # ImageMagick
HAS_FFMPEG=0;  check_cmd ffmpeg  && HAS_FFMPEG=1
echo ""

if [[ "$HAS_ZIP" = "0" ]]; then
  error "'zip' is required. Install with: apt-get install zip"
  exit 1
fi

if [[ "$CONVERT_HEIC" = "1" && "$HAS_CONVERT" = "0" && "$HAS_FFMPEG" = "0" ]]; then
  warn "Neither ImageMagick nor ffmpeg found — HEIC files will NOT be converted to JPEG."
  warn "Install ImageMagick: apt-get install imagemagick"
  CONVERT_HEIC=0
fi

# ── Step 1: Find live photo pairs ─────────────────────────────────────────────
info "Scanning for live photo pairs in: $ORIGINALS_DIR"

declare -a LIVE_PAIRS_STILL=()   # still image paths
declare -a LIVE_PAIRS_VIDEO=()   # matching video paths

while IFS= read -r -d '' video_file; do
  base="${video_file%.*}"
  still=""

  # Check for matching still in order of preference
  for ext in jpg JPG jpeg JPEG heic HEIC; do
    candidate="${base}.${ext}"
    if [[ -f "$candidate" ]]; then
      still="$candidate"
      break
    fi
  done

  if [[ -n "$still" ]]; then
    LIVE_PAIRS_STILL+=("$still")
    LIVE_PAIRS_VIDEO+=("$video_file")
  fi
done < <(find "$ORIGINALS_DIR" -type f \( -iname "*.mov" -o -iname "*.mp4" \) -print0)

PAIR_COUNT="${#LIVE_PAIRS_VIDEO[@]}"

if [[ "$PAIR_COUNT" -eq 0 ]]; then
  info "No live photo pairs found. Nothing to do."
  exit 0
fi

success "Found ${PAIR_COUNT} live photo pair(s)."
echo ""

# Print the pairs
for i in "${!LIVE_PAIRS_VIDEO[@]}"; do
  echo -e "  ${CYAN}Still:${RESET} ${LIVE_PAIRS_STILL[$i]}"
  echo -e "  ${RED}Video:${RESET} ${LIVE_PAIRS_VIDEO[$i]}"
  echo ""
done

# ── Step 2: Backup ────────────────────────────────────────────────────────────
info "Step 1/3 — Backing up live photo pairs to zip..."

if [[ "$DRY_RUN" = "0" ]]; then
  mkdir -p "$BACKUP_DIR"

  # Build list of all files to back up
  ALL_FILES=()
  for i in "${!LIVE_PAIRS_VIDEO[@]}"; do
    ALL_FILES+=("${LIVE_PAIRS_STILL[$i]}" "${LIVE_PAIRS_VIDEO[$i]}")
  done

  # Zip with relative paths
  (
    cd "$ORIGINALS_DIR"
    zip_args=()
    for f in "${ALL_FILES[@]}"; do
      rel="${f#$ORIGINALS_DIR/}"
      zip_args+=("$rel")
    done
    zip -r "$BACKUP_ZIP" "${zip_args[@]}" -x "*.DS_Store"
  )

  BACKUP_SIZE="$(du -sh "$BACKUP_ZIP" | cut -f1)"
  success "Backup created: $BACKUP_ZIP (${BACKUP_SIZE})"
else
  warn "[DRY RUN] Would create backup zip: $BACKUP_ZIP"
fi
echo ""

# ── Step 3: Convert HEIC → JPEG (if applicable) ───────────────────────────────
info "Step 2/3 — Converting HEIC stills to JPEG where needed..."

HEIC_CONVERTED=0
HEIC_SKIPPED=0

for i in "${!LIVE_PAIRS_STILL[@]}"; do
  still="${LIVE_PAIRS_STILL[$i]}"
  ext="${still##*.}"

  if [[ "${ext,,}" == "heic" ]]; then
    new_still="${still%.*}.jpg"

    if [[ "$DRY_RUN" = "0" && "$CONVERT_HEIC" = "1" ]]; then
      if [[ "$HAS_CONVERT" = "1" ]]; then
        convert "$still" "$new_still" 2>/dev/null && {
          rm "$still"
          LIVE_PAIRS_STILL[$i]="$new_still"
          success "Converted: $(basename "$still") → $(basename "$new_still")"
          ((HEIC_CONVERTED++)) || true
        }
      elif [[ "$HAS_FFMPEG" = "1" ]]; then
        ffmpeg -i "$still" "$new_still" -loglevel quiet && {
          rm "$still"
          LIVE_PAIRS_STILL[$i]="$new_still"
          success "Converted: $(basename "$still") → $(basename "$new_still")"
          ((HEIC_CONVERTED++)) || true
        }
      fi
    elif [[ "$DRY_RUN" = "1" ]]; then
      warn "[DRY RUN] Would convert HEIC → JPEG: $still"
      ((HEIC_CONVERTED++)) || true
    else
      warn "Skipping HEIC conversion (CONVERT_HEIC=0): $(basename "$still")"
      ((HEIC_SKIPPED++)) || true
    fi
  fi
done

if [[ "$HEIC_CONVERTED" -eq 0 && "$HEIC_SKIPPED" -eq 0 ]]; then
  info "No HEIC files found — all stills are already JPEG."
fi
echo ""

# ── Step 4: Remove video sidecars ─────────────────────────────────────────────
info "Step 3/3 — Removing video sidecar files..."

DELETED=0
FAILED=0

for video in "${LIVE_PAIRS_VIDEO[@]}"; do
  if [[ "$DRY_RUN" = "0" ]]; then
    if rm "$video" 2>/dev/null; then
      success "Deleted: $video"
      ((DELETED++)) || true
    else
      error "Failed to delete: $video"
      ((FAILED++)) || true
    fi
  else
    warn "[DRY RUN] Would delete: $video"
    ((DELETED++)) || true
  fi
done
echo ""

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "  Live pairs found    : ${PAIR_COUNT}"
echo -e "  HEIC→JPEG converted : ${HEIC_CONVERTED}"
echo -e "  Videos removed      : ${DELETED}"
[[ "$FAILED" -gt 0 ]] && echo -e "  ${RED}Failures            : ${FAILED}${RESET}"
[[ "$DRY_RUN" = "0" ]] && echo -e "  Backup saved to     : ${BACKUP_ZIP}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}\n"

if [[ "$DRY_RUN" = "0" && "$PAIR_COUNT" -gt 0 ]]; then
  echo -e "${GREEN}✓ Done! Run PhotoPrism re-index to apply changes:${RESET}"
  echo -e "  ${CYAN}docker exec -it photoprism photoprism index --cleanup${RESET}\n"
fi