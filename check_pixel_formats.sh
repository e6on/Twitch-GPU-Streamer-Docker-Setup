#!/bin/bash

#
# check_video_formats.sh
#
# This script scans a directory for video files, reports the resolution, frame rate,
# and pixel format for each, and provides a summary. This is useful for diagnosing FFmpeg errors related to
# incompatible pixel formats, especially when using hardware acceleration.
#
# Usage:
#   ./check_pixel_formats.sh [--root-only] /path/to/your/videos
#
# You can also run this inside your Docker container:
#   docker-compose exec streamer ./check_pixel_formats.sh /videos
#

set -euo pipefail

# --- Configuration ---
# Add or remove video file extensions as needed.
VIDEO_EXTENSIONS="mp4 mkv mov avi webm ts"

# --- Script Logic ---

ROOT_ONLY=false
if [[ "$1" == "--root-only" ]]; then
    ROOT_ONLY=true
    shift # Remove the flag from the arguments list
fi

if [[ $# -eq 0 ]]; then
    echo "Error: No directory specified."
    echo "Usage: $0 [--root-only] <directory>"
    exit 1
fi

VIDEO_DIR="$1"

if [[ ! -d "$VIDEO_DIR" ]]; then
    echo "Error: Directory '$VIDEO_DIR' not found."
    exit 1
fi

# Build the find command arguments dynamically from the extensions list.
find_args=("$VIDEO_DIR" -type f)

if [[ "$ROOT_ONLY" == "true" ]]; then
    find_args+=(-maxdepth 1)
    echo "🔍 Scanning root of '$VIDEO_DIR' only..."
else
    echo "🔍 Scanning for video files in '$VIDEO_DIR' (including subdirectories)..."
fi
echo
first=true
for ext in $VIDEO_EXTENSIONS; do
    if [ "$first" = "true" ]; then
        find_args+=(\( -iname "*.$ext")
    else
        find_args+=(-o -iname "*.$ext")
    fi
    first=false
done
find_args+=(\))

# Use a temporary file to store pixel formats for aggregation. This is a portable
# alternative to associative arrays, which are not supported in older bash versions.
TMP_FILE=$(mktemp)
TMP_FILE_RES=$(mktemp)
TMP_FILE_FPS=$(mktemp)
trap 'rm -f "$TMP_FILE"' EXIT # Ensure temp file is cleaned up on exit
trap 'rm -f "$TMP_FILE_RES"' EXIT
trap 'rm -f "$TMP_FILE_FPS"' EXIT

find "${find_args[@]}" -print0 | while IFS= read -r -d '' file; do
    # Use a single ffprobe call for efficiency
    info=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate,pix_fmt -of default=noprint_wrappers=1:nokey=1 "$file")
    
    # Read info into variables
    res=$(echo "$info" | sed -n '1p' | tr -d '\n')x$(echo "$info" | sed -n '2p' | tr -d '\n')
    fps=$(echo "$info" | sed -n '3p' | tr -d '\n')
    pix_fmt=$(echo "$info" | sed -n '4p' | tr -d '\n')

    echo "File: ${file} -> Res: ${res:-'N/A'}, FPS: ${fps:-'N/A'}, Format: ${pix_fmt:-'N/A'}"
    [ -n "$pix_fmt" ] && echo "$pix_fmt" >> "$TMP_FILE"
    [ -n "$res" ] && echo "$res" >> "$TMP_FILE_RES"
    [ -n "$fps" ] && echo "$fps" >> "$TMP_FILE_FPS"
done

echo -e "\n--- 📊 Video Property Summary ---\n"
echo "--- Resolutions ---"
sort "$TMP_FILE_RES" | uniq -c | awk '{ printf "%-15s | %s files\n", "Resolution: " $2, $1 }'
echo -e "\n--- Frame Rates (FPS) ---"
sort "$TMP_FILE_FPS" | uniq -c | awk '{ printf "%-15s | %s files\n", "FPS: " $2, $1 }'
echo -e "\n--- Pixel Formats ---"
sort "$TMP_FILE" | uniq -c | awk '{ printf "%-15s | %s files\n", "Format: " $2, $1 }'
echo -e "\n------------------------------"