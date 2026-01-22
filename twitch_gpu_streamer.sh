#!/bin/bash

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# Cleanup handler for graceful shutdown
cleanup() {
    local exit_code=$?
    log "WAR" "Received shutdown signal. Cleaning up..."

    # Kill ffmpeg processes
    if [[ -n "${FFMPEG_PID:-}" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log "INF" "Stopping ffmpeg (PID: $FFMPEG_PID)..."
        kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        wait "$FFMPEG_PID" 2>/dev/null || true
    fi

    # Kill monitor process
    if [[ -n "${MONITOR_PID:-}" ]] && kill -0 "$MONITOR_PID" 2>/dev/null; then
        kill -TERM "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi

    # Clean up temp files
    rm -f "${LOG_DIR}/last_played.txt" "${VIDEO_PLAYLIST}.tmp.$$" "${MUSIC_LIST}.tmp.$$" 2>/dev/null || true

    log "WAR" "Cleanup complete. Exiting with code ${exit_code}."
    exit "$exit_code"
}

# Set up signal traps
trap cleanup EXIT TERM INT

# Read environment variables (docker-compose passes these in). Provide sensible defaults.
# Use TWITCH_INGEST_URL or fallback to the default Twitch RTMP URL.
TWITCH_URL="${TWITCH_INGEST_URL:-rtmp://live.twitch.tv/app}"
# Remove trailing slash from TWITCH_URL if it exists to prevent double slashes
TWITCH_URL="${TWITCH_URL%/}"
# Twitch stream key should be set via TWITCH_STREAM_KEY (loaded from the .env file in compose)
STREAM_KEY="${TWITCH_STREAM_KEY:-}" 

# Logging: allow customizing script log file and enable ffmpeg log separately
LOG_DIR="${LOG_DIR:-/data}"
SCRIPT_LOG_FILE="${SCRIPT_LOG_FILE:-$LOG_DIR/stream_log.txt}"
ENABLE_SCRIPT_LOG_FILE="${ENABLE_SCRIPT_LOG_FILE:-false}"
ENABLE_FFMPEG_LOG_FILE="${ENABLE_FFMPEG_LOG_FILE:-false}"
FFMPEG_LOG_FILE="${FFMPEG_LOG_FILE:-$LOG_DIR/ffmpeg.log}"
FFMPEG_LOG_LEVEL="${FFMPEG_LOG_LEVEL:-}" # e.g., error, info, verbose, debug

# VIDEO_DIR is set in docker-compose (e.g. /videos). Allow an explicit VIDEO_PLAYLIST to override.
VIDEO_DIR="${VIDEO_DIR:-/videos}"
VIDEO_FILE_TYPES="${VIDEO_FILE_TYPES:-mp4 mkv mov avi webm flv}"
# Path for the generated video playlist
VIDEO_PLAYLIST="${VIDEO_PLAYLIST:-$LOG_DIR/video_list.txt}"

# Optional background music playlist (concat format)
MUSIC_DIR="${MUSIC_DIR:-/music}"
MUSIC_LIST="${MUSIC_LIST:-$LOG_DIR/music_list.txt}"
CONCAT_MUSIC_FILE="${LOG_DIR:-/data}/music.m4a"
ENABLE_MUSIC="${ENABLE_MUSIC:-false}"
MUSIC_VOLUME="${MUSIC_VOLUME:-1.0}"
MUSIC_FILE_TYPES="${MUSIC_FILE_TYPES:-mp3 flac wav ogg m4a aac}"

# Network retry settings
MAX_RETRY_ATTEMPTS="${MAX_RETRY_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-10}"

# Global PID variables
FFMPEG_PID=""
MONITOR_PID=""

# Streaming resolution & bitrates
STREAM_RESOLUTION="${STREAM_RESOLUTION:-1280x720}"
STREAM_FRAMERATE="${STREAM_FRAMERATE:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"

# Calculate GOP size for a 2-second keyframe interval, as recommended by Twitch.
GOP_SIZE=$(awk -v fps="$STREAM_FRAMERATE" 'BEGIN { printf "%.0f", fps * 2 }')

# Calculate buffer size as 2.5x video bitrate.
# Extract numeric part and unit (e.g., 'k' or 'M') from VIDEO_BITRATE.
bitrate_num=$(echo "$VIDEO_BITRATE" | sed -E 's/([0-9.]+).*/\1/')
bitrate_unit=$(echo "$VIDEO_BITRATE" | sed -E 's/[0-9.]+(.*)/\1/')
# Use awk for floating point multiplication, then format as an integer.
bufsize_num=$(awk -v br="$bitrate_num" 'BEGIN { printf "%.0f", br * 2.5 }')
BUFSIZE="${bufsize_num}${bitrate_unit}"

# VA-API device and hardware acceleration toggle
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
ENABLE_HW_ACCEL="${ENABLE_HW_ACCEL:-false}"

# Loop and reshuffle control
ENABLE_LOOP="${ENABLE_LOOP:-false}"
# Delay in seconds before restarting stream after a loop (0 = instant restart)
LOOP_RESTART_DELAY="${LOOP_RESTART_DELAY:-0}"
# Show per-file progress percentage updates
ENABLE_PROGRESS_UPDATES="${ENABLE_PROGRESS_UPDATES:-false}"

# FFmpeg resilience/options and basic flags
FFMPEG_OPTS=(
    -nostdin                         # Disable interaction on standard input. Essential for background tasks.
    -avoid_negative_ts make_zero     # Shift negative timestamps to start at 0, required for FLV.
    -fflags "+discardcorrupt+genpts" # Drop corrupted frames and generate missing PTS if needed.
)

# VA-API options only used if enabled and device exists
VAAPI_OPTS=()

# Decide whether to use VA-API or software encoding
if [[ "$ENABLE_HW_ACCEL" == "true" && -e "$VAAPI_DEVICE" ]]; then
    VAAPI_OPTS=(
        -hwaccel vaapi                  # Uses the VAAPI (Video Acceleration API) hardware acceleration for decoding the input video.
        -vaapi_device "$VAAPI_DEVICE"   # Specifies the VAAPI device to use.
        -hwaccel_output_format vaapi    # Sets the output pixel format of the hardware-accelerated decoder to VAAPI.
    )
    USE_HWACCEL=true
else
    USE_HWACCEL=false
fi

# Create a scaled filter for the chosen encoder
if [[ "$USE_HWACCEL" == "true" ]]; then
    VIDEO_FILTER="scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}:format=nv12" # VAAPI scaling
else
    VIDEO_FILTER="scale=${STREAM_RESOLUTION%x*}:${STREAM_RESOLUTION#*x}:flags=lanczos" # Software scaling
fi
# Decide if a video filter should be used. For now, this is always true if a filter is defined.
USE_VIDEO_FILTER="${USE_VIDEO_FILTER:-true}"

# --- Logging Setup ---

# Define color codes for logging.
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[1;36m'
readonly NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    local message="$2"
    local no_newline_flag="${3:-}" # Optional: -n to suppress newline. Default to empty string.
    local timestamp
    local color="${NC}"
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        INF) color="${GREEN}" ;;
        MUS) color="${GREEN}" ;;
        WAR) color="${YELLOW}" ;;
        VID) color="${CYAN}" ;;
        ERR) color="${RED}" ;;
    esac

    if [[ "$no_newline_flag" == "-n" ]]; then
        # Construct the full string first, then print it with printf.
        # This prevents the '%' in the progress from being interpreted as a format specifier.
        # We use a newline to force the output buffer to flush, then use an ANSI escape
        # code `\e[1A` to move the cursor back up one line. This is more reliable
        # than just using a carriage return `\r` in some terminal environments.
        >&2 printf "\r\e[K%b\n\e[1A" "${color}${timestamp} [${level}] ${message}${NC}"
        # Do not write these transient progress updates to the file log to keep it clean.
    else
        # Log to stderr for colored console output (with newline)
        >&2 echo -e "${color}${timestamp} [${level}] ${message}${NC}"

        # Log to file if enabled, without color codes
        if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
            # Ensure a newline is printed if the previous line was a progress update
            echo "${timestamp} [${level}] ${message}" >> "${SCRIPT_LOG_FILE}"
        fi
    fi
}

# Function to format seconds into a human-readable string (d h:m:s)
format_duration() {
    local input="${1:-0}"
    # Take only the first line and word (in case of contaminated input)
    input=$(echo "$input" | head -n1 | awk '{print $1}')
    local total_seconds=${input%.*} # Use integer part of seconds

    # Validate that total_seconds is a number
    if ! [[ "$total_seconds" =~ ^[0-9]+$ ]]; then
        echo "0h:00m:00s"
        return
    fi

    if [[ -z "$total_seconds" || "$total_seconds" -le 0 ]]; then
        echo "0h:00m:00s"
        return
    fi

    local days=$((total_seconds / 86400))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))

    local formatted_duration=""
    if [[ $days -gt 0 ]]; then
        formatted_duration+="${days}d "
    fi
    formatted_duration+=$(printf "%dh:%02dm:%02ds" "$hours" "$minutes" "$seconds")
    echo "$formatted_duration"
}

# Cache file for playlist durations to avoid recalculating
DURATION_CACHE="${LOG_DIR}/duration_cache.txt"

# Function to calculate total duration of a playlist with caching
get_playlist_duration() {
    local playlist_file="$1"
    local source_dir="${2:-}"
    local use_cache="${3:-true}"
    local total_duration=0
    local file_count=0

    if [[ ! -f "$playlist_file" ]]; then
        echo "0 0"
        return
    fi

    # Quick file count check
    file_count=$(grep -c "^file " "$playlist_file" 2>/dev/null || echo 0)
    
    # Cache key based on source directory and file count (shuffle-friendly)
    # This allows cache hits even when playlist is regenerated in different order
    local cache_key
    cache_key=$(echo "${source_dir}:${file_count}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "${source_dir}_${file_count}")
    
    if [[ "$use_cache" == "true" && -f "$DURATION_CACHE" ]]; then
        local cached_line
        # Look for cache entry with matching key and file count
        # Format: cache_key:duration file_count (space before file_count)
        cached_line=$(grep "^${cache_key}:" "$DURATION_CACHE" 2>/dev/null | grep " ${file_count}$" || true)
        if [[ -n "$cached_line" ]]; then
            log "INF" "Cache hit for $(basename "$source_dir") (${file_count} files) - using cached duration"
            # Return cached values: duration and file count
            echo "$cached_line" | cut -d':' -f2-
            return
        fi
    fi
    
    # Cache miss - need to calculate
    log "INF" "Cache miss for $(basename "$source_dir") (${file_count} files) - calculating durations..."

    local playlist_dir
    playlist_dir=$(dirname "$playlist_file")

    # Process the entire playlist file with awk for efficiency and to avoid subshell issues.
    # Filter output to only get the final summary line (duration and file count)
    local result
    result=$(awk -v playlist_dir="$playlist_dir" '
        BEGIN { FS = "\x27"; total_duration = 0; file_count = 0; }
        /^file / {
            file_count++;
            relative_path = $2;
            full_path = (relative_path ~ /^\//) ? relative_path : playlist_dir "/" relative_path;

            # Use ffprobe with explicit output format to get only the duration value
            cmd = "ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"" full_path "\" 2>&1";
            duration = "";
            while ((cmd | getline line) > 0) {
                # Only capture lines that are pure numbers (duration values)
                if (line ~ /^[0-9]+(\.[0-9]+)?$/) {
                    duration = line;
                }
            }
            close(cmd);

            if (duration != "" && duration > 0) {
                total_duration += duration;
            }
        }
        END { printf "%.6f %d\n", total_duration, file_count; }
    ' "$playlist_file" | tail -n 1)

    # Validate the result format (should be "number number")
    if ! echo "$result" | grep -qE '^[0-9]+(\.[0-9]+)? [0-9]+$'; then
        log "WAR" "Invalid duration result for $playlist_file, using 0"
        result="0 0"
    fi

    # Cache the result with new format: cache_key:duration file_count
    if [[ "$use_cache" == "true" ]]; then
        mkdir -p "$(dirname "$DURATION_CACHE")"
        # Remove old entries for this cache key and add new one
        grep -v "^${cache_key}:" "$DURATION_CACHE" 2>/dev/null > "${DURATION_CACHE}.tmp" || true
        echo "${cache_key}:${result}" >> "${DURATION_CACHE}.tmp"
        mv "${DURATION_CACHE}.tmp" "$DURATION_CACHE" 2>/dev/null || true
    fi

    echo "$result"
}

# Generic function to generate a playlist file from a directory of media files.
# Handles special characters robustly using NUL-delimited pipes.
generate_playlist() {
    local source_dir="$1"
    local file_types="$2"
    local output_file="$3"
    local media_type="$4"

    log "INF" "Generating ${media_type} list from ${source_dir} for types: ${file_types}..."

    # Sanitize file_types to handle values passed with quotes from docker-compose
    local sanitized_file_types="${file_types%\"}"
    sanitized_file_types="${sanitized_file_types#\"}"

    if [[ -z "${sanitized_file_types}" ]]; then
        log "WAR" "No file types specified for ${media_type}. Playlist will be empty."
        : > "${output_file}"
        return
    fi

    # Build the find command arguments dynamically
    local -a find_args
    find_args=("${source_dir}" -type f)

    local first=true
    for ext in ${sanitized_file_types}; do
        if [[ "$first" == "true" ]]; then
            find_args+=(\( -iname "*.${ext}")
            first=false
        else
            find_args+=(-o -iname "*.${ext}")
        fi
    done
    find_args+=(\))

    # Choose sort or shuffle
    local sort_or_shuffle_cmd
    if [[ "${ENABLE_SHUFFLE:-false}" == "true" ]]; then
        log "INF" "Shuffle mode enabled for ${media_type}."
        sort_or_shuffle_cmd=(shuf -z)
    else
        sort_or_shuffle_cmd=(sort -z)
    fi

    # Use find -print0 with NUL-delimited read to handle special characters
    # Write to temp file first, then move to avoid empty file overwrites
    local temp_file="${output_file}.tmp.$$"
    {
        find "${find_args[@]}" -print0 2>/dev/null | "${sort_or_shuffle_cmd[@]}" | while IFS= read -r -d '' file; do 
            echo "file '$file'"
        done
    } > "$temp_file"

    # Move temp file to final location (atomic operation)
    mv "$temp_file" "$output_file" 2>/dev/null || true
    local count
    count=$(grep -c "^file " "${output_file}" 2>/dev/null || echo 0)
    log "INF" "${media_type} file list generated at ${output_file} with ${count} entries"
}

# Wrapper to generate music playlist
generate_musiclist() {
    if [[ "${ENABLE_MUSIC}" != "true" ]]; then
        return
    fi
    mkdir -p "$(dirname "$MUSIC_LIST")"
    generate_playlist "${MUSIC_DIR}" "${MUSIC_FILE_TYPES}" "${MUSIC_LIST}" "Music"

    # Check if playlist is empty
    local count
    count=$(grep -c "^file " "${MUSIC_LIST}" 2>/dev/null || echo 0)
    if [[ $count -eq 0 ]]; then
        log "WAR" "Found no music files under $MUSIC_DIR - disabling music."
        ENABLE_MUSIC="false"
        rm -f "$MUSIC_LIST" "$CONCAT_MUSIC_FILE"
    else
        # Log music playlist duration
        local duration_info
        duration_info=$(get_playlist_duration "$MUSIC_LIST" "$MUSIC_DIR")
        local formatted_duration
        formatted_duration=$(format_duration "$(echo "$duration_info" | cut -d' ' -f1)")
        log "WAR" "Music playlist duration: ${formatted_duration} - $(echo "$duration_info" | cut -d' ' -f2) files"

        # Concatenate music files into a single file for stable looping
        log "MUS" "Concatenating music files into a single track for looping..."
        if ffmpeg -y -f concat -safe 0 -i "$MUSIC_LIST" -c copy "$CONCAT_MUSIC_FILE" >/dev/null 2>&1; then
            log "MUS" "Successfully created concatenated music file at ${CONCAT_MUSIC_FILE}"
        else
            log "ERR" "Failed to concatenate music files. Disabling music for this session."
            ENABLE_MUSIC="false"
            rm -f "$CONCAT_MUSIC_FILE"
        fi
    fi
}

# Wrapper to generate video playlist
generate_videolist() {
    log "VID" "Checking for videos in ${VIDEO_DIR}..."
    if [[ ! -d "$VIDEO_DIR" ]]; then
        log "ERR" "Video source directory not found at ${VIDEO_DIR}. Please mount it in your docker-compose.yml. ABORTING."
        exit 3
    fi

    mkdir -p "$(dirname "$VIDEO_PLAYLIST")"
    generate_playlist "${VIDEO_DIR}" "${VIDEO_FILE_TYPES}" "${VIDEO_PLAYLIST}" "Video"

    # Check if playlist is empty
    local count
    count=$(grep -c "^file " "${VIDEO_PLAYLIST}" 2>/dev/null || echo 0)
    if [[ $count -eq 0 ]]; then
        log "ERR" "Found no video files in ${VIDEO_DIR} matching types '${VIDEO_FILE_TYPES}'. ABORTING."
        rm -f "${VIDEO_PLAYLIST}"
        exit 4
    fi
}

# Helper to parse progress output
parse_progress_output() {
    local output="$1"
    local file_ext_regex="$2"

    # Filter out the concatenated music file; allow 'no difference'
    local filtered_output
    filtered_output="$(echo "$output" | grep -v -- "$CONCAT_MUSIC_FILE" || true)"

    # Extract filename (best-effort)
    local current_file
    current_file="$(echo "$filtered_output" \
      | grep -Eo "(/|\.\/)?[^[:space:]]+\.(${file_ext_regex})" \
      | head -n 1 || true)"

    # Extract percent (best-effort)
    local progress_percent
    progress_percent="$(echo "$output" \
      | grep -Eo '^[[:space:]]*[0-9]+(\.[0-9]+)?%' \
      | head -n 1 || true)"

    echo "$current_file|$progress_percent"
}

# Function to monitor ffmpeg using the 'progress' command in the background
monitor_ffmpeg_progress() {
  local last_logged_file=""
  # Persist last file even if we are killed (TERM/INT) or exit normally.
  persist_last_played() {
    if [[ -n "$last_logged_file" ]]; then
      echo "$last_logged_file" > "${LOG_DIR}/last_played.txt"
    fi
    # Print a final newline when monitoring stops
    >&2 echo
  }
  trap persist_last_played EXIT TERM INT

  # Give ffmpeg a moment to start and open a file before we start monitoring
  sleep 3

  # --- Sanitize VIDEO_FILE_TYPES and build alternation regex (Pre-calculated) ---
  local sanitized_types="${VIDEO_FILE_TYPES%\"}"
  sanitized_types="${sanitized_types#\"}"
  sanitized_types="${sanitized_types%\'}"
  sanitized_types="${sanitized_types#\'}"
  local file_ext_regex
    file_ext_regex="$(printf '%s\n' "$sanitized_types" | paste -sd'|' -)"

  while pidof -x ffmpeg >/dev/null 2>&1; do
    # Take a snapshot; don't let a transient error kill the loop
    local output
    output="$(progress -c ffmpeg -q 2>/dev/null || true)"
    if [[ -z "$output" ]]; then
      sleep 1
      continue
    fi

    # Parse output using helper
    local result
    result=$(parse_progress_output "$output" "$file_ext_regex")
    local current_file="${result%%|*}"
    local progress_percent="${result##*|}"

    if [[ -n "$current_file" && "$current_file" != "$last_logged_file" ]]; then
      [[ -n "$last_logged_file" ]] && >&2 echo

      local file_counter_str=""
      if [[ -f "$VIDEO_PLAYLIST" ]]; then
        local total_files
        total_files=$(grep -c "^file " "$VIDEO_PLAYLIST" || echo 0)
        local line_num
        line_num=$(grep -nF "file '$current_file'" "$VIDEO_PLAYLIST" | head -n1 | cut -d: -f1 || true)
        if [[ -n "$line_num" ]]; then
          file_counter_str="[${line_num}/${total_files}]"
        fi
      fi

      log "VID" "Now Playing #${loop_count}${file_counter_str}: $(basename "$current_file") (${progress_percent:-0.0%})"
      last_logged_file="$current_file"
    elif [[ "${ENABLE_PROGRESS_UPDATES}" == "true" && -n "$current_file" && -n "$progress_percent" ]]; then
      log "VID" "Progress: $(basename "$current_file") (${progress_percent})" "-n"
    fi

    sleep 2
  done

  if [[ -n "$last_logged_file" ]]; then
    echo "$last_logged_file" > "${LOG_DIR}/last_played.txt"
  fi
  >&2 echo
}

# Check for permissions
check_permissions() {
    if [[ ! -w "$LOG_DIR" ]]; then
         log "ERR" "Log directory '$LOG_DIR' is not writable. Please check permissions."
         exit 1
    fi
}

# Check for required dependencies
check_dependencies() {
    local deps=("ffmpeg" "ffprobe" "sort" "awk" "sed" "grep" "date" "find")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log "ERR" "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

# Helper to build input arguments
build_input_args() {
    local playlist_path="$1"
    echo -re -f concat -safe 0 -i "$playlist_path"
}

# Helper to check if video has audio stream
has_audio_stream() {
    local video_file="$1"
    local audio_streams
    audio_streams=$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "$video_file" 2>/dev/null | wc -l)
    [[ $audio_streams -gt 0 ]]
}

# Helper to build audio and filter arguments
build_audio_and_filter_args() {

    local use_video_filter="${1}"
    local enable_music="${2}"
    local music_volume="${3}"
    local audio_bitrate="${4}"

    local -a args=()

    if [[ "$enable_music" == "true" && -f "$CONCAT_MUSIC_FILE" ]]; then
        log "MUS" "Music enabled, replacing original video audio. Video filter: ${use_video_filter}"
        args+=(-stream_loop -1 -i "$CONCAT_MUSIC_FILE") # Loop music infinitely

        # Determine if audio needs re-encoding based on volume
        if [[ $(awk -v vol="$music_volume" 'BEGIN { print (vol == 1.0) }') -eq 1 ]]; then
            log "MUS" "Music volume is 1.0, copying audio stream directly (-c:a copy)."
            args+=(-c:a copy)
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and map filtered video and music audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]" -map "[vout]" -map "1:a")
            else
                args+=(-map 0:v -map "1:a") # Map video and music audio directly
            fi
        else
            log "MUS" "Applying music volume (${music_volume}). Audio will be re-encoded."
            args+=(-c:a aac -ar 44100 -b:a "${audio_bitrate}")
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and adjust music volume and map filtered video and adjusted music audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];[1:a]volume=${music_volume},asetpts=PTS-STARTPTS[aud]" -map "[vout]" -map "[aud]")
            else
                # Adjust music volume and map video and adjusted music audio
                args+=(-filter_complex "[1:a]volume=${music_volume},asetpts=PTS-STARTPTS[aud]" -map 0:v -map "[aud]")
            fi
        fi
        args+=(-shortest) # End stream when the video playlist finishes
    else
        log "VID" "Music is disabled. Using video audio directly. Video filter: ${use_video_filter}"
        # Check if the first video has audio before copying
        local first_video
        first_video=$(grep -m1 "^file " "$VIDEO_PLAYLIST" | sed "s/^file '\(.*\)'/\1/" || true)

        if [[ -n "$first_video" ]] && has_audio_stream "$first_video"; then
            log "VID" "Copying audio stream without re-encoding (-c:a copy)."
            args+=(-c:a copy)
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and map filtered video and original audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]" -map "[vout]" -map "0:a?")
            else
                args+=(-map 0:v -map "0:a?") # Map video and audio directly (? makes it optional)
            fi
        else
            log "WAR" "Video has no audio stream. Encoding silent audio."
            args+=(-c:a aac -ar 44100 -b:a "${audio_bitrate}")
            if [[ "$use_video_filter" == "true" ]]; then
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];anullsrc=r=44100:cl=stereo[aud]" -map "[vout]" -map "[aud]")
            else
                args+=(-f lavfi -i anullsrc=r=44100:cl=stereo -map 0:v -map 1:a)
            fi
        fi
    fi

    AUDIO_ARGS=("${args[@]}")
}

# Helper to build encoding arguments
build_codec_args() {
    local use_hwaccel="$1"
    local -a args=()

    if [[ "$use_hwaccel" == "true" ]]; then
        args+=(
             -c:v h264_vaapi                # Use VAAPI H.264 encoder
             -profile:v high                # High profile for better quality
             -idr_interval 1                # Insert IDR frames at every keyframe
             -aud 1                         # Insert Access Unit Delimiter
             -sei timing+recovery_point     # Insert SEI messages for timing and recovery points
             -async_depth 4                 # Audio sync depth
             -coder cabac                   # Use CABAC entropy coding
             -quality 0                     # Use best quality mode
             -r "${STREAM_FRAMERATE}"       # Set frame rate
             -fps_mode cfr                  # Constant frame rate
             -rc_mode CBR                   # Constant bitrate mode
             -b:v "${VIDEO_BITRATE}"        # Set video bitrate
             -maxrate "${VIDEO_BITRATE}"    # Set max bitrate
             -bufsize "${BUFSIZE}"          # Set buffer size
             -g "${GOP_SIZE}"               # Set GOP size
             -keyint_min "${GOP_SIZE}"      # Set minimum GOP size
             )
    else
        args+=(
             -c:v libx264                   # Use software x264 encoder
             -preset veryfast               # Use veryfast preset for low latency
             -r "${STREAM_FRAMERATE}"       # Set frame rate
             -fps_mode cfr                  # Constant frame rate
             -minrate "${VIDEO_BITRATE}"    # Set minimum bitrate
             -maxrate "${VIDEO_BITRATE}"    # Set maximum bitrate
             -bufsize "${BUFSIZE}"          # Set buffer size
             -g "${GOP_SIZE}"               # Set GOP size
             -keyint_min "${GOP_SIZE}"      # Set minimum GOP size
             )
    fi
    CODEC_ARGS=("${args[@]}")
}

# Detect network errors from ffmpeg output
detect_network_error() {
    local exit_code="$1"
    local log_file="${2:-}"

    # Exit codes that indicate network issues
    if [[ $exit_code -eq 1 || $exit_code -eq 255 ]]; then
        if [[ -n "$log_file" && -f "$log_file" ]]; then
            # Check for common network error messages
            if grep -qE "(Connection (refused|reset|timed out)|Network is unreachable|I/O error|RTMP.*error)" "$log_file" 2>/dev/null; then
                return 0
            fi
        fi
        # Assume network error for these exit codes even without log confirmation
        return 0
    fi
    return 1
}

# Function to start the ffmpeg stream with dynamically constructed arguments
start_ffmpeg_stream() {
    log "VID" "Preparing to start FFmpeg stream..."

    local -a cmd
    cmd=(ffmpeg "${FFMPEG_OPTS[@]}" "${VAAPI_OPTS[@]}")

    # --- Input Configuration ---
    # shellcheck disable=SC2207
    cmd+=( $(build_input_args "$1") )

    # --- Music and Filter Configuration ---
    # Populate AUDIO_ARGS global
    build_audio_and_filter_args "$USE_VIDEO_FILTER" "$ENABLE_MUSIC" "$MUSIC_VOLUME" "$AUDIO_BITRATE"
    cmd+=("${AUDIO_ARGS[@]}")

    # --- Codec Configuration ---
    # Populate CODEC_ARGS global
    build_codec_args "$USE_HWACCEL"
    cmd+=("${CODEC_ARGS[@]}")

    # --- Output Configuration ---
    cmd+=(
         -max_muxing_queue_size 4096        # Increase muxing queue size to prevent buffer overflows
         -rw_timeout 15000000               # Set RTMP timeout to 15 seconds (in microseconds)
         -flvflags no_duration_filesize     # Do not include duration/filesize metadata in FLV
         -rtmp_live live                    # Set RTMP live mode
         -f flv "$TWITCH_URL/$STREAM_KEY"   # Output to Twitch RTMP URL
         )

    # --- Progress Monitoring Check ---
    if ! command -v progress &> /dev/null; then
        log "WAR" "'progress' command not found. Cannot monitor currently playing file."
        log "WAR" "Please ensure 'progress' is installed in your Docker image."
    fi

    # --- Logging and Execution ---
    if [[ "$ENABLE_FFMPEG_LOG_FILE" == "true" ]]; then
        local log_level="${FFMPEG_LOG_LEVEL:-info}"
        cmd+=(-loglevel "${log_level}") # Set ffmpeg log level
        log "VID" "Executing FFmpeg command (logging to ${FFMPEG_LOG_FILE}): ${cmd[*]}"
        # Run ffmpeg in the background to get its PID, redirecting logs to a file.
        "${cmd[@]}" >> "$FFMPEG_LOG_FILE" 2>&1 &
    else
        cmd+=(-loglevel warning) # Set ffmpeg log level
        log "VID" "Executing FFmpeg command: ${cmd[*]}"
        # If script logging is enabled, pipe ffmpeg's stderr through `tee` to
        # simultaneously print to the console and append to the script log file.
        # Otherwise, just run ffmpeg and let its stderr go to the console directly.
        if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
            "${cmd[@]}" >/dev/null 2> >(tee -a "${SCRIPT_LOG_FILE}" >&2) &
        else
            "${cmd[@]}" &
        fi
    fi

    local ffmpeg_pid=$!
    local monitor_pid=""

    # Start the progress monitor in the background if the command exists
    if command -v progress &> /dev/null; then
        log "INF" "Starting 'progress' monitor for the 'ffmpeg' command."
        monitor_ffmpeg_progress &
        monitor_pid=$!  # Capture the monitor's PID
    fi

    # Use 'wait' to block the script until the ffmpeg process completes.
    # This makes ffmpeg behave like a foreground process for the main script loop.
    wait "$ffmpeg_pid"
    local exit_code=$?

    # Clean up the background monitor process when ffmpeg is done
    if [[ -n "$monitor_pid" ]]; then
        # Give the monitor time to detect ffmpeg exit and flush the last file
        # The monitor loop uses `pidof -x ffmpeg` and will exit on its own.
        # Just wait for it (avoid killing before it writes last_played.txt).
        # If it’s already gone, wait will return immediately.
        # Add a small grace if you want:
        for _ in 1 2 3; do
            kill -0 "$monitor_pid" 2>/dev/null || break
            sleep 1
        done
        wait "$monitor_pid" 2>/dev/null || true
        # Read the last played file from the temp file
        local last_played_file=""
        if [[ -f "${LOG_DIR}/last_played.txt" ]]; then
            # Read the last file path and clean up the temp file
            last_played_file=$(<"${LOG_DIR}/last_played.txt")
            rm -f "${LOG_DIR}/last_played.txt"  # Clean up
        fi

        # If we know the last file, log its context in the playlist
        if [[ -n "$last_played_file" ]]; then
            local playlist_file="$1"
            # Find the line number of the last played file in the playlist
            local line_info
            line_info=$(grep -nFx "file '$last_played_file'" "$playlist_file" || true)

            if [[ -n "$line_info" ]]; then
                local line_num="${line_info%%:*}"
                local total_lines
                total_lines=$(wc -l < "$playlist_file")

                # Log the last played file
                log "ERR" "Last Played: $(basename "$last_played_file") (File ${line_num}/${total_lines})"

                # Log the next file if it exists
                if [[ "$line_num" -lt "$total_lines" ]]; then
                    local next_line_num=$((line_num + 1))
                    local next_file_line
                    next_file_line=$(sed -n "${next_line_num}p" "$playlist_file")
                    log "ERR" "  ->   Next: $(basename "${next_file_line#file \'}")"
                fi
            fi
        fi
    fi

    # Return the exit code of ffmpeg
    return $exit_code
}

main() {
    # Validate mandatory config
    if [[ -z "$STREAM_KEY" || "$STREAM_KEY" == "your_stream_key_here" ]]; then
        log "ERR" "TWITCH_STREAM_KEY is not set. Please add it to your .env or docker-compose and pass it into the container."
        exit 1
    fi

    # Check for required dependencies
    check_dependencies

    # Check for environment permissions
    check_permissions

    # Initialize duration cache
    mkdir -p "$(dirname "$DURATION_CACHE")"
    touch "$DURATION_CACHE" 2>/dev/null || true

    log "WAR" "=== STREAM SCRIPT START ==="
    log "INF" "Source: $VIDEO_PLAYLIST"
    log "INF" "Resolution: $STREAM_RESOLUTION"
    log "INF" "VA-API Device: $VAAPI_DEVICE"
    log "INF" "TWITCH ingest URL: $TWITCH_URL"
    log "INF" "Framerate: ${STREAM_FRAMERATE}fps, GOP Size: ${GOP_SIZE} (2s keyframe interval)"
    log "INF" "VIDEO bitrate: $VIDEO_BITRATE, AUDIO bitrate: $AUDIO_BITRATE"
    log "INF" "Buffer Size (bufsize): $BUFSIZE"
    log "INF" "Hardware acceleration: $USE_HWACCEL"
    log "INF" "Music Enabled: $ENABLE_MUSIC"
    log "INF" "Looping Enabled: $ENABLE_LOOP"
    log "INF" "Shuffle Enabled: ${ENABLE_SHUFFLE:-false}"
    log "INF" "FFmpeg log file: $FFMPEG_LOG_FILE (enabled: $ENABLE_FFMPEG_LOG_FILE)"
    [[ -n "$FFMPEG_LOG_LEVEL" ]] && log "INF" "FFmpeg log level override: $FFMPEG_LOG_LEVEL"

    # Initial wait for the video playlist to be generated by the sidecar
    generate_videolist

    # Main stream loop
    local loop_count=0
    while true; do
        loop_count=$((loop_count + 1))
        log "WAR" "=== STREAMING LOOP START (Loop #${loop_count}) ==="
        # If shuffle is enabled, regenerate the video playlist on each loop.
        if [[ "${ENABLE_SHUFFLE:-false}" == "true" && $loop_count -gt 1 ]]; then
            generate_videolist
        fi

        # --- Generate/Shuffle Music Playlist ---
        if [[ "$ENABLE_MUSIC" == "true" ]]; then
            # Log music directory presence and summary
            if [[ -d "$MUSIC_DIR" ]]; then
                music_count=$(find "$MUSIC_DIR" -type f -print 2>/dev/null | wc -l || echo 0)
                log "MUS" "Music dir: $MUSIC_DIR exists; file count: $music_count"
                generate_musiclist
            else
                log "WAR" "Music dir $MUSIC_DIR does not exist inside container. Disabling music for this loop."
                ENABLE_MUSIC="false"
            fi
        fi

        # Log video playlist duration
        local duration_info
        duration_info=$(get_playlist_duration "$VIDEO_PLAYLIST" "$VIDEO_DIR")
        local total_duration
        total_duration=$(echo "$duration_info" | cut -d' ' -f1)
        local file_count
        file_count=$(echo "$duration_info" | cut -d' ' -f2)
        log "WAR" "Video playlist duration: $(format_duration "$total_duration") - ${file_count} files"

        # --- Launch FFmpeg with retry logic for network errors ---
        local retry_count=0
        local exit_code=1
        local should_retry=true

        while [[ $retry_count -lt $MAX_RETRY_ATTEMPTS && "$should_retry" == "true" ]]; do
            if [[ $retry_count -gt 0 ]]; then
                log "WAR" "Retry attempt ${retry_count}/${MAX_RETRY_ATTEMPTS} in ${RETRY_DELAY} seconds..."
                sleep "$RETRY_DELAY"
            fi

            # Temporarily disable -e so we can capture the exit code and continue.
            set +e
            start_ffmpeg_stream "$VIDEO_PLAYLIST"
            exit_code=$?
            set -e

            log "INF" "FFmpeg process exited with code ${exit_code}."

            # Check if this was a network error that should be retried
            if detect_network_error "$exit_code" "${FFMPEG_LOG_FILE}"; then
                log "ERR" "Network error detected. Will retry if attempts remain."
                retry_count=$((retry_count + 1))
            else
                # Not a network error, don't retry
                should_retry=false
            fi
        done

        if [[ $retry_count -ge $MAX_RETRY_ATTEMPTS ]]; then
            log "ERR" "Max retry attempts (${MAX_RETRY_ATTEMPTS}) reached. Giving up."
        fi

        # --- Loop Control ---
        if [[ "$ENABLE_LOOP" != "true" ]]; then
            log "WAR" "Looping is disabled. Exiting script."
            break
        fi

        if [[ $LOOP_RESTART_DELAY -gt 0 ]]; then
            log "INF" "Looping enabled. Restarting stream in ${LOOP_RESTART_DELAY} seconds..."
            sleep "$LOOP_RESTART_DELAY"
        else
            log "INF" "Looping enabled. Restarting stream immediately..."
        fi
    done
}

# --- Main Execution ---
# Launch the main logic
main
