#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/livephoto-convert.sh?$(date +%s))"
#!/bin/bash
# =============================================================================
# PhotoPrism Live Photo → Still Converter
# =============================================================================
# Handles two formats:
#   1. Samsung Motion Photos — video embedded inside the JPEG (XMP tags)
#   2. Apple Live Photos     — separate .mov sidecar alongside JPEG/HEIC
#
# Usage:
#   bash convert_live_photos.sh /mnt/sec/media/photos/chiult
#
# Dry run:
#   DRY_RUN=1 bash convert_live_photos.sh /mnt/sec/media/photos/chiult
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Progress helpers ──────────────────────────────────────────────────────────
PROGRESS_TOTAL=0
PROGRESS_CURRENT=0

draw_progress() {
  local activity="$1"
  local pct=0
  [[ "$PROGRESS_TOTAL" -gt 0 ]] && pct=$(( PROGRESS_CURRENT * 100 / PROGRESS_TOTAL ))

  local filled=$(( pct * 30 / 100 ))
  local empty=$(( 30 - filled ))
  local bar=""
  for ((i=0; i<filled; i++)); do bar+="█"; done
  for ((i=0; i<empty; i++));  do bar+="░"; done

  # Overwrite the last 2 lines
  printf "\r\033[1A\033[2K\033[1A\033[2K"
  printf "${BOLD}PROGRESS${RESET}  ${PURPLE}${bar}${RESET}  ${pct}%%\n"
  printf "${BOLD}ACTIVITY${RESET}  ${CYAN}${activity}${RESET}\n"
}

init_progress() {
  PROGRESS_TOTAL=$1
  PROGRESS_CURRENT=0
  # Print initial two lines so draw_progress has lines to overwrite
  printf "${BOLD}PROGRESS${RESET}  ${PURPLE}░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░${RESET}  0%%\n"
  printf "${BOLD}ACTIVITY${RESET}  starting...\n"
}

tick_progress() {
  ((PROGRESS_CURRENT++)) || true
  draw_progress "$1"
}

finish_progress() {
  PROGRESS_CURRENT=$PROGRESS_TOTAL
  draw_progress "$1"
  echo ""
}

# ── Args & config ─────────────────────────────────────────────────────────────
ORIGINALS_DIR="${1:-}"
DRY_RUN="${DRY_RUN:-0}"
BACKUP_DIR="${BACKUP_DIR:-$(dirname "${ORIGINALS_DIR:-/tmp}")/live_photo_backups}"

if [[ -z "$ORIGINALS_DIR" ]]; then
  error "Usage: $0 /path/to/photos"
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

[[ "$DRY_RUN" = "1" ]] && warn "DRY RUN MODE — listing actions only, nothing will be changed.\n"

# ── Auto-install dependencies ─────────────────────────────────────────────────
install_pkg() {
  local pkg="$1"
  info "Installing ${pkg}..."
  apt-get install -y "$pkg" -qq >/dev/null 2>&1 && success "Installed: ${pkg}" || {
    error "Failed to install ${pkg}. Try manually: apt-get install ${pkg}"
    return 1
  }
}

ensure_cmd() {
  local cmd="$1"; local pkg="${2:-$1}"
  if command -v "$cmd" &>/dev/null; then
    success "Found: $cmd"
  else
    warn "Not found: $cmd — installing ${pkg}..."
    install_pkg "$pkg"
  fi
}

info "Checking dependencies..."
ensure_cmd exiftool libimage-exiftool-perl
ensure_cmd zip zip
ensure_cmd convert imagemagick
ensure_cmd ffmpeg ffmpeg
echo ""

command -v exiftool &>/dev/null || { error "exiftool could not be installed. Cannot continue."; exit 1; }
command -v zip      &>/dev/null || { error "zip could not be installed. Cannot continue."; exit 1; }

HAS_CONVERT=0; command -v convert &>/dev/null && HAS_CONVERT=1
HAS_FFMPEG=0;  command -v ffmpeg  &>/dev/null && HAS_FFMPEG=1

# ── Step 1a: Find Samsung Motion Photos ──────────────────────────────────────
info "Scanning for Samsung Motion Photos..."

declare -a SAMSUNG_PHOTOS=()

while IFS= read -r -d '' jpg; do
  if exiftool -q -q -MicroVideo -MotionPhoto "$jpg" 2>/dev/null | grep -qiE "^(Micro Video|Motion Photo)\s*:\s*1"; then
    SAMSUNG_PHOTOS+=("$jpg")
  fi
done < <(find "$ORIGINALS_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -print0)

SAMSUNG_COUNT="${#SAMSUNG_PHOTOS[@]}"
success "Samsung Motion Photos found: ${SAMSUNG_COUNT}"

# ── Step 1b: Find Apple Live Photos ──────────────────────────────────────────
info "Scanning for Apple Live Photos..."

declare -a APPLE_STILLS=()
declare -a APPLE_MOVS=()

while IFS= read -r -d '' mov; do
  base="${mov%.*}"
  still=""
  for ext in jpg JPG jpeg JPEG heic HEIC; do
    if [[ -f "${base}.${ext}" ]]; then
      still="${base}.${ext}"
      break
    fi
  done
  if [[ -n "$still" ]]; then
    APPLE_STILLS+=("$still")
    APPLE_MOVS+=("$mov")
  fi
done < <(find "$ORIGINALS_DIR" -type f -iname "*.mov" -print0)

APPLE_COUNT="${#APPLE_MOVS[@]}"
success "Apple Live Photos found: ${APPLE_COUNT}"
echo ""

TOTAL=$((SAMSUNG_COUNT + APPLE_COUNT))

if [[ "$TOTAL" -eq 0 ]]; then
  info "No live photos found. Nothing to do."
  exit 0
fi

# ── Step 2: Backup ────────────────────────────────────────────────────────────
info "Backing up ${TOTAL} live photo file(s)..."

if [[ "$DRY_RUN" = "0" ]]; then
  mkdir -p "$BACKUP_DIR"
  declare -a ALL_BACKUP_FILES=()

  for f in "${SAMSUNG_PHOTOS[@]+"${SAMSUNG_PHOTOS[@]}"}"; do
    ALL_BACKUP_FILES+=("${f#$ORIGINALS_DIR/}")
  done
  for i in "${!APPLE_MOVS[@]+"${!APPLE_MOVS[@]}"}"; do
    ALL_BACKUP_FILES+=("${APPLE_STILLS[$i]#$ORIGINALS_DIR/}")
    ALL_BACKUP_FILES+=("${APPLE_MOVS[$i]#$ORIGINALS_DIR/}")
  done

  (cd "$ORIGINALS_DIR" && zip -r "$BACKUP_ZIP" "${ALL_BACKUP_FILES[@]}" -q)
  BACKUP_SIZE="$(du -sh "$BACKUP_ZIP" | cut -f1)"
  success "Backup created: $BACKUP_ZIP (${BACKUP_SIZE})"
else
  warn "[DRY RUN] Would backup ${TOTAL} file(s) to: $BACKUP_ZIP"
fi
echo ""

# ── Step 3: Convert Samsung Motion Photos ────────────────────────────────────
SAMSUNG_CONVERTED=0; SAMSUNG_FAILED=0

if [[ "$SAMSUNG_COUNT" -gt 0 ]]; then
  info "Converting Samsung Motion Photos..."
  init_progress "$SAMSUNG_COUNT"

  for jpg in "${SAMSUNG_PHOTOS[@]}"; do
    fname="$(basename "$jpg")"
    if [[ "$DRY_RUN" = "0" ]]; then
      if exiftool -overwrite_original \
          -MicroVideo= -MicroVideoOffset= -MicroVideoLength= \
          -MicroVideoPresentationTimestampUs= \
          -MotionPhoto= -MotionPhotoVersion= \
          -MotionPhotoPresentationTimestampUs= \
          -EmbeddedVideoType= -EmbeddedVideoFile= \
          -q "$jpg" 2>/dev/null; then
        ((SAMSUNG_CONVERTED++)) || true
      else
        ((SAMSUNG_FAILED++)) || true
        fname="[FAILED] $fname"
      fi
    else
      ((SAMSUNG_CONVERTED++)) || true
    fi
    tick_progress "stripping $fname"
  done
  finish_progress "samsung motion photos done"
fi

# ── Step 4: Convert Apple Live Photos ────────────────────────────────────────
APPLE_CONVERTED=0; APPLE_FAILED=0; HEIC_CONVERTED=0

if [[ "$APPLE_COUNT" -gt 0 ]]; then
  info "Converting Apple Live Photos..."
  init_progress "$APPLE_COUNT"

  for i in "${!APPLE_MOVS[@]}"; do
    still="${APPLE_STILLS[$i]}"
    mov="${APPLE_MOVS[$i]}"
    fname="$(basename "$mov")"
    ext="${still##*.}"

    if [[ "$DRY_RUN" = "0" ]]; then
      # Convert HEIC → JPEG if needed
      if [[ "${ext,,}" == "heic" ]]; then
        new_still="${still%.*}.jpg"
        converted=0
        [[ "$HAS_CONVERT" = "1" ]] && convert "$still" "$new_still" 2>/dev/null && converted=1
        [[ "$converted" = "0" && "$HAS_FFMPEG" = "1" ]] && ffmpeg -i "$still" "$new_still" -loglevel quiet 2>/dev/null && converted=1
        if [[ "$converted" = "1" ]]; then
          rm "$still"
          ((HEIC_CONVERTED++)) || true
        fi
      fi

      # Delete the .mov sidecar
      if rm "$mov" 2>/dev/null; then
        ((APPLE_CONVERTED++)) || true
      else
        ((APPLE_FAILED++)) || true
        fname="[FAILED] $fname"
      fi
    else
      ((APPLE_CONVERTED++)) || true
    fi
    tick_progress "removing $fname"
  done
  finish_progress "apple live photos done"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
TOTAL_CONVERTED=$((SAMSUNG_CONVERTED + APPLE_CONVERTED))
TOTAL_FAILED=$((SAMSUNG_FAILED + APPLE_FAILED))

echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Summary${RESET}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}"
echo -e "  Samsung Motion Photos   : ${SAMSUNG_COUNT} found, ${SAMSUNG_CONVERTED} converted"
echo -e "  Apple Live Photos       : ${APPLE_COUNT} found, ${APPLE_CONVERTED} converted"
[[ "${HEIC_CONVERTED:-0}" -gt 0 ]] && \
echo -e "  HEIC→JPEG conversions   : ${HEIC_CONVERTED}"
[[ "$TOTAL_FAILED" -gt 0 ]] && \
echo -e "  ${RED}Failures                : ${TOTAL_FAILED}${RESET}"
[[ "$DRY_RUN" = "0" ]] && \
echo -e "  Backup saved to         : ${BACKUP_ZIP}"
echo -e "${BOLD}════════════════════════════════════════════════════${RESET}\n"

if [[ "$DRY_RUN" = "0" && "$TOTAL_CONVERTED" -gt 0 ]]; then
  echo -e "${GREEN}✓ Done! Re-index PhotoPrism to apply changes:${RESET}"
  echo -e "  ${CYAN}docker exec -it photoprism photoprism index --cleanup${RESET}\n"
fi