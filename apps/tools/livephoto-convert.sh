#!/usr/bin/env bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/apps/tools/livephoto-convert.sh?$(date +%s))"
# =============================================================================
# PhotoPrism Live Photo → Still Converter
# =============================================================================
# Handles two formats:
#   1. Samsung Motion Photos — video embedded inside the JPEG (XMP tags)
#   2. Apple Live Photos     — separate .mov sidecar alongside JPEG/HEIC
#
# What this script does:
#   1. Scans for both types of live photos
#   2. Backs them all up into a timestamped zip archive
#   3. Samsung: strips embedded video using exiftool
#   4. Apple:   deletes the .mov sidecar; converts HEIC→JPEG if needed
#   5. Prints a summary report
#
# Requirements: exiftool, zip (auto-installed if missing)
#               imagemagick or ffmpeg (for HEIC→JPEG, auto-installed)
#
# Usage:
#   bash convert_live_photos.sh /mnt/sec/media/photos/chiult
#
# Dry run (no changes made):
#   DRY_RUN=1 bash convert_live_photos.sh /mnt/sec/media/photos/chiult
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

if [[ -z "$ORIGINALS_DIR" ]]; then
  error "Usage: $0 /path/to/photos"
  error "       DRY_RUN=1 $0 /path/to/photos"
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
echo -e "${BOLD}  (Samsung Motion Photos + Apple Live Photos)${RESET}"
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
info "Scanning for Samsung Motion Photos (embedded video in JPEG)..."

declare -a SAMSUNG_PHOTOS=()

while IFS= read -r -d '' jpg; do
  if exiftool -q -q -MicroVideo -MotionPhoto "$jpg" 2>/dev/null | grep -qiE "^(Micro Video|Motion Photo)\s*:\s*1"; then
    SAMSUNG_PHOTOS+=("$jpg")
  fi
done < <(find "$ORIGINALS_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -print0)

SAMSUNG_COUNT="${#SAMSUNG_PHOTOS[@]}"
success "Samsung Motion Photos found: ${SAMSUNG_COUNT}"

if [[ "$SAMSUNG_COUNT" -gt 0 ]]; then
  for f in "${SAMSUNG_PHOTOS[@]}"; do
    echo -e "    ${CYAN}→${RESET} $f"
  done
fi
echo ""

# ── Step 1b: Find Apple Live Photos ──────────────────────────────────────────
info "Scanning for Apple Live Photos (.mov sidecar alongside JPEG/HEIC)..."

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
    # Extra check: verify it's an Apple Live Photo via exiftool ContentIdentifier
    if exiftool -q -q -ContentIdentifier -LivePhotoVideoIndex "$still" 2>/dev/null | grep -qiE "^(Content Identifier|Live Photo Video Index)\s*:"; then
      APPLE_STILLS+=("$still")
      APPLE_MOVS+=("$mov")
    else
      # Fallback: if .mov matches a JPEG/HEIC by name, treat as live photo pair anyway
      APPLE_STILLS+=("$still")
      APPLE_MOVS+=("$mov")
    fi
  fi
done < <(find "$ORIGINALS_DIR" -type f -iname "*.mov" -print0)

APPLE_COUNT="${#APPLE_MOVS[@]}"
success "Apple Live Photos found: ${APPLE_COUNT}"

if [[ "$APPLE_COUNT" -gt 0 ]]; then
  for i in "${!APPLE_MOVS[@]}"; do
    echo -e "    ${CYAN}Still:${RESET} ${APPLE_STILLS[$i]}"
    echo -e "    ${RED}Video:${RESET} ${APPLE_MOVS[$i]}"
  done
fi
echo ""

TOTAL=$((SAMSUNG_COUNT + APPLE_COUNT))

if [[ "$TOTAL" -eq 0 ]]; then
  info "No live photos found. Nothing to do."
  exit 0
fi

# ── Step 2: Backup ────────────────────────────────────────────────────────────
info "Step 1/3 — Backing up all live photo files..."

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

  (
    cd "$ORIGINALS_DIR"
    zip -r "$BACKUP_ZIP" "${ALL_BACKUP_FILES[@]}"
  )
  BACKUP_SIZE="$(du -sh "$BACKUP_ZIP" | cut -f1)"
  success "Backup created: $BACKUP_ZIP (${BACKUP_SIZE})"
else
  warn "[DRY RUN] Would backup ${TOTAL} live photo file(s) to: $BACKUP_ZIP"
fi
echo ""

# ── Step 3: Process Samsung Motion Photos ────────────────────────────────────
if [[ "$SAMSUNG_COUNT" -gt 0 ]]; then
  info "Step 2/3 — Stripping embedded video from Samsung Motion Photos..."

  SAMSUNG_CONVERTED=0
  SAMSUNG_FAILED=0

  for jpg in "${SAMSUNG_PHOTOS[@]}"; do
    if [[ "$DRY_RUN" = "0" ]]; then
      if exiftool -overwrite_original \
          -MicroVideo= \
          -MicroVideoOffset= \
          -MicroVideoLength= \
          -MicroVideoPresentationTimestampUs= \
          -MotionPhoto= \
          -MotionPhotoVersion= \
          -MotionPhotoPresentationTimestampUs= \
          -EmbeddedVideoType= \
          -EmbeddedVideoFile= \
          -q "$jpg" 2>/dev/null; then
        success "Stripped: $(basename "$jpg")"
        ((SAMSUNG_CONVERTED++)) || true
      else
        error "Failed: $jpg"
        ((SAMSUNG_FAILED++)) || true
      fi
    else
      warn "[DRY RUN] Would strip motion video from: $(basename "$jpg")"
      ((SAMSUNG_CONVERTED++)) || true
    fi
  done
  echo ""
else
  SAMSUNG_CONVERTED=0; SAMSUNG_FAILED=0
  info "Step 2/3 — No Samsung Motion Photos to process, skipping."
  echo ""
fi

# ── Step 4: Process Apple Live Photos ────────────────────────────────────────
if [[ "$APPLE_COUNT" -gt 0 ]]; then
  info "Step 3/3 — Processing Apple Live Photos..."

  APPLE_CONVERTED=0
  APPLE_FAILED=0
  HEIC_CONVERTED=0

  for i in "${!APPLE_MOVS[@]}"; do
    still="${APPLE_STILLS[$i]}"
    mov="${APPLE_MOVS[$i]}"
    ext="${still##*.}"

    # Convert HEIC → JPEG if needed
    if [[ "${ext,,}" == "heic" ]]; then
      new_still="${still%.*}.jpg"
      if [[ "$DRY_RUN" = "0" ]]; then
        converted=0
        if [[ "$HAS_CONVERT" = "1" ]]; then
          convert "$still" "$new_still" 2>/dev/null && converted=1
        elif [[ "$HAS_FFMPEG" = "1" ]]; then
          ffmpeg -i "$still" "$new_still" -loglevel quiet 2>/dev/null && converted=1
        fi
        if [[ "$converted" = "1" ]]; then
          rm "$still"
          success "HEIC→JPEG: $(basename "$still") → $(basename "$new_still")"
          ((HEIC_CONVERTED++)) || true
        else
          warn "Could not convert HEIC: $(basename "$still") — keeping as-is"
        fi
      else
        warn "[DRY RUN] Would convert HEIC→JPEG: $(basename "$still")"
        ((HEIC_CONVERTED++)) || true
      fi
    fi

    # Delete the .mov sidecar
    if [[ "$DRY_RUN" = "0" ]]; then
      if rm "$mov" 2>/dev/null; then
        success "Deleted sidecar: $(basename "$mov")"
        ((APPLE_CONVERTED++)) || true
      else
        error "Failed to delete: $mov"
        ((APPLE_FAILED++)) || true
      fi
    else
      warn "[DRY RUN] Would delete sidecar: $(basename "$mov")"
      ((APPLE_CONVERTED++)) || true
    fi
  done
  echo ""
else
  APPLE_CONVERTED=0; APPLE_FAILED=0; HEIC_CONVERTED=0
  info "Step 3/3 — No Apple Live Photos to process, skipping."
  echo ""
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