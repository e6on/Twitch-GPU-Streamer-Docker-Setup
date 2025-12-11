#!/usr/bin/env bash
set -euo pipefail

# ---------------------- CONFIG ----------------------
IN_DIR="${IN_DIR:-.}"                  # Source folder (mp3/m4a/wav/flac/aac)
OUT_DIR="${OUT_DIR:-./_normalized}"    # Destination for normalized .m4a files

# Loudness targets (EBU R128)
TARGET_I="${TARGET_I:--26}"            # Integrated loudness (LUFS) was -16; try -18, -20, or -23 for quieter results
TARGET_TP="${TARGET_TP:--1.5}"         # True peak (dBTP)
TARGET_LRA="${TARGET_LRA:-11}"         # Loudness range (LU)

# Uniform output params (for consistent results)
OUT_SR="${OUT_SR:-44100}"              # Sample rate
OUT_CH="${OUT_CH:-2}"                  # Channels
OUT_BR="${OUT_BR:-64k}"                # Bitrate (e.g., 64k/96k/128k)

# Source extensions to include (space-separated)
GLOB_EXT="${GLOB_EXT:-mp3}"

# -------------------- PREP & CHECKS -----------------
mkdir -p "$OUT_DIR"

# Build file list (POSIX-friendly; avoids GNU realpath)
# We’ll collect absolute paths by prefixing with $PWD.
FILES=()
for ext in $GLOB_EXT; do
  # Use find to include files with spaces; read with while loop.
  # macOS find supports -print0 only on BSD? It doesn’t; so use IFS trick.
  while IFS= read -r -d '' f; do
    # If path is not absolute, prefix $PWD
    case "$f" in
      /*) abs="$f" ;;
      *)  abs="$PWD/$f" ;;
    esac
    FILES+=("$abs")
  done < <(find "$IN_DIR" -maxdepth 1 -type f -name "*.${ext}" -print0)
done

# Sort deterministically (macOS has /usr/bin/sort)
IFS=$'\n' FILES=($(printf '%s\n' "${FILES[@]}" | sort))
unset IFS

if (( ${#FILES[@]} == 0 )); then
  echo "No input files found in '$IN_DIR' matching: $GLOB_EXT" >&2
  exit 1
fi

echo "Found ${#FILES[@]} file(s). Normalizing to: I=${TARGET_I} LUFS, TP=${TARGET_TP} dBTP, LRA=${TARGET_LRA} LU"
echo "Output: AAC-LC ${OUT_SR} Hz, ${OUT_CH} ch, ${OUT_BR} → $OUT_DIR"
echo

# ---------------- TWO-PASS NORMALIZATION ------------
norm_one() {
  local in="$1"
  local base out stats meas_I meas_TP meas_LRA meas_thresh offset

  base="$(basename "$in")"
  out="$OUT_DIR/${base%.*}.m4a"

  echo "→ Analyzing: $base"
  # Pass 1: analysis (print_format=summary for easy parsing)
  # We direct output to null muxer; keep stderr for parsing.
  stats="$(ffmpeg -hide_banner -nostdin -y \
    -i "$in" \
    -vn \
    -filter:a "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:print_format=summary" \
    -ar "$OUT_SR" -ac "$OUT_CH" \
    -f null - 2>&1 || true)"

  # Extract measured values (portable parsing with grep/awk)
  meas_I="$(echo "$stats"      | grep -m1 'Input Integrated' | awk '{print $3}')"   || true
  meas_TP="$(echo "$stats"     | grep -m1 'Input True Peak'  | awk '{print $4}')"   || true
  meas_LRA="$(echo "$stats"    | grep -m1 'Input LRA'        | awk '{print $3}')"   || true
  meas_thresh="$(echo "$stats" | grep -m1 'Input Threshold'  | awk '{print $3}')"   || true
  offset="$(echo "$stats"      | grep -m1 'Target Offset'    | awk '{print $3}')"   || true

  if [[ -z "${meas_I:-}" || -z "${meas_TP:-}" || -z "${meas_LRA:-}" || -z "${meas_thresh:-}" || -z "${offset:-}" ]]; then
    echo "  ! Could not parse loudnorm stats; falling back to one-pass normalization."
    ffmpeg -hide_banner -nostdin -y \
      -i "$in" -vn \
      -filter:a "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}" \
      -c:a aac -b:a "$OUT_BR" -ar "$OUT_SR" -ac "$OUT_CH" \
      -map_metadata 0 -movflags +faststart \
      "$out"
    echo "  ✓ Normalized (one-pass) → $out"
    return
  fi

  echo "  Stats → I:${meas_I} LUFS, TP:${meas_TP} dBTP, LRA:${meas_LRA} LU, Thr:${meas_thresh} LUFS, Off:${offset} LU"

  # Pass 2: apply exact correction
  ffmpeg -hide_banner -nostdin -y \
    -i "$in" -vn \
    -filter:a "loudnorm=I=${TARGET_I}:TP=${TARGET_TP}:LRA=${TARGET_LRA}:measured_I=${meas_I}:measured_TP=${meas_TP}:measured_LRA=${meas_LRA}:measured_thresh=${meas_thresh}:offset=${offset}:linear=true:print_format=summary" \
    -c:a aac -b:a "$OUT_BR" -ar "$OUT_SR" -ac "$OUT_CH" \
    -map_metadata 0 -movflags +faststart \
    "$out"

  echo "  ✓ Normalized (two-pass) → $out"
}

for f in "${FILES[@]}"; do
  norm_one "$f"
done

echo
echo "✓ All files normalized to: $OUT_DIR"
echo "You can now build a playlist or merge separately if you want a single file."
