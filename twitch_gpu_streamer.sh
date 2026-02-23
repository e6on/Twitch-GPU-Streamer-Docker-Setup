#!/bin/bash

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# Ensure UTF-8 locale for correct character counting and Unicode support
export LC_ALL=C.UTF-8

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================

# Process IDs
FFMPEG_PID=""
MONITOR_PID=""

# State tracking
LAST_LOGGED_FILE=""
LOOP_COUNT=0

# Performance metrics
STREAM_START_TIME=""

# ============================================================================
# LOGGING CONFIGURATION
# ============================================================================

# Define color codes for logging.
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[1;36m'
readonly BLUE='\033[1;34m'
readonly MAGENTA='\033[0;35m'
readonly NC='\033[0m' # No Color

# Logging levels
declare -A LOG_LEVEL_VALUES=(
    [DBG]=0
    [INF]=1
    [MUS]=1
    [VID]=1
    [WAR]=2
    [ERR]=3
    [SET]=1
)

# Current log level (can be overridden by environment)
CURRENT_LOG_LEVEL="${LOG_LEVEL:-INF}"
CURRENT_LOG_LEVEL_VALUE=${LOG_LEVEL_VALUES[$CURRENT_LOG_LEVEL]:-1}

# ============================================================================
# ENVIRONMENT CONFIGURATION
# ============================================================================

# Read environment variables (docker-compose passes these in). Provide sensible defaults.
# Use TWITCH_INGEST_URL or fallback to the default Twitch RTMP URL.
TWITCH_URL="${TWITCH_INGEST_URL:-rtmp://live.twitch.tv/app}"
# Remove trailing slash from TWITCH_URL if it exists to prevent double slashes
TWITCH_URL="${TWITCH_URL%/}"
# Twitch stream key should be set via TWITCH_STREAM_KEY (loaded from the .env file in compose)
STREAM_KEY="${TWITCH_STREAM_KEY:-}" 

# Logging: allow customizing script log file and enable ffmpeg log separately
LOG_DIR="${LOG_DIR:-/data}"
SCRIPT_LOG_FILE="${SCRIPT_LOG_FILE:-$LOG_DIR/stream.log}"
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

# Streaming resolution & bitrates
STREAM_RESOLUTION="${STREAM_RESOLUTION:-1280x720}"
STREAM_FRAMERATE="${STREAM_FRAMERATE:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"
AUDIO_SAMPLE_RATE="${AUDIO_SAMPLE_RATE:-44100}"

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

# Cache file for playlist durations to avoid recalculating
DURATION_CACHE="${LOG_DIR}/duration_cache.txt"

# State persistence
LAST_PLAYED_FILE="${LOG_DIR}/last_played.txt"
STREAM_STATE_FILE="${LOG_DIR}/stream_state.json"

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
        -hwaccel_output_format vaapi    # Sets the output pixel format of the hardware-accelerated decoder.
        -extra_hw_frames 32             # Extra VAAPI surface buffers to prevent filter graph reinitialization failures when switching between files in concat. If the crash still happens occasionally, bump -extra_hw_frames to 20 or 32.
        -probesize 50M                  # More thorough format detection
        -analyzeduration 50M            # Spend more time analyzing input streams
    )
    USE_HWACCEL=true
else
    USE_HWACCEL=false
fi

# Create a scaled filter for the chosen encoder.
# For VA-API we must explicitly upload system-memory frames to GPU surfaces with
# hwupload before calling scale_vaapi, otherwise FFmpeg cannot bridge the format
# gap between the software decoder output and the hardware scaler input.
# format=nv12 on the upload step pins the surface format so scale_vaapi has a
# known pixel format to work with on every input file regardless of source format.
if [[ "$USE_HWACCEL" == "true" ]]; then
    VIDEO_FILTER="scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}:format=nv12" # VAAPI scaling
else
    VIDEO_FILTER="scale=${STREAM_RESOLUTION%x*}:${STREAM_RESOLUTION#*x}:flags=lanczos" # Software scaling
fi
# Decide if a video filter should be used. For now, this is always true if a filter is defined.
USE_VIDEO_FILTER="${USE_VIDEO_FILTER:-true}"

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

# Logging function with level filtering
log() {
    local level="$1"
    local message="$2"
    local no_newline_flag="${3:-}" # Optional: -n to suppress newline. Default to empty string.
    
    # Check if this log level should be printed
    local level_value=${LOG_LEVEL_VALUES[$level]:-1}
    if [[ $level_value -lt $CURRENT_LOG_LEVEL_VALUE ]]; then
        return 0
    fi
    
    local timestamp
    local color="${NC}"
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$level" in
        DBG) color="${MAGENTA}" ;;
        INF) color="${GREEN}" ;;
        MUS) color="${GREEN}" ;;
        WAR) color="${YELLOW}" ;;
        VID) color="${CYAN}" ;;
        ERR) color="${RED}" ;;
        SET) color="${BLUE}" ;;
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

# Debug logging helper
log_debug() {
    log "DBG" "$1"
}

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

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

# Helper to pad string with spaces or truncate
pad_str() {
    local str="$1"
    local width="$2"
    local len=${#str}
    if [[ $len -gt $width ]]; then
        echo "${str:0:$((width-3))}..."
    else
        printf "%-${width}s" "$str"
    fi
}

# Helper to draw a horizontal line
draw_line() {
    local width="$1"
    local char="$2"
    if [[ $width -gt 0 ]]; then
        printf -- "${char}%.0s" $(seq 1 "$width")
    fi
}

# ============================================================================
# CLEANUP AND SIGNAL HANDLING
# ============================================================================

# Cleanup handler for graceful shutdown
cleanup() {
    local exit_code=$?
    log "WAR" "Received shutdown signal. Cleaning up..."

    # Save stream state before exiting
    save_stream_state

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
    rm -f "${VIDEO_PLAYLIST}.tmp.$$" "${MUSIC_LIST}.tmp.$$" 2>/dev/null || true

    log "WAR" "Cleanup complete. Exiting with code ${exit_code}."
    exit "$exit_code"
}

# Set up signal traps
trap cleanup EXIT TERM INT

# ============================================================================
# STATE PERSISTENCE
# ============================================================================

# Save current stream state to JSON file
save_stream_state() {
    local state_file="$STREAM_STATE_FILE"
    local current_time=$(date +%s)

    # The monitor subprocess writes the last-played path to LAST_PLAYED_FILE.
    # Read it here so the parent process always has an up-to-date value even
    # though subprocess variable assignments cannot propagate back to the parent.
    if [[ -f "${LAST_PLAYED_FILE}" ]]; then
        local file_from_disk
        file_from_disk=$(<"${LAST_PLAYED_FILE}")
        if [[ -n "$file_from_disk" ]]; then
            LAST_LOGGED_FILE="$file_from_disk"
        fi
    fi
    
    # Create JSON state
    cat > "$state_file" <<EOF
{
  "last_played": "${LAST_LOGGED_FILE:-}",
  "loop_count": ${LOOP_COUNT},
  "last_update": ${current_time},
  "stream_start_time": "${STREAM_START_TIME:-}"
}
EOF
    
    log_debug "Stream state saved to ${state_file}"
}

# Load stream state from JSON file
load_stream_state() {
    local state_file="$STREAM_STATE_FILE"
    
    if [[ ! -f "$state_file" ]]; then
        log_debug "No previous stream state found"
        return 0
    fi
    
    # Parse JSON (simple grep/sed approach for basic fields)
    if [[ -r "$state_file" ]]; then
        local last_played=$(grep -o '"last_played": "[^"]*"' "$state_file" 2>/dev/null | cut -d'"' -f4 || echo "")
        local loop_count=$(grep -o '"loop_count": [0-9]*' "$state_file" 2>/dev/null | awk '{print $2}' || echo "0")
        
        if [[ -n "$last_played" ]]; then
            log "INF" "Recovered last played: $(basename "$last_played")"
            LAST_LOGGED_FILE="$last_played"
        fi
        
    fi
}

# ============================================================================
# DEPENDENCY AND PERMISSION CHECKS
# ============================================================================

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

# ============================================================================
# DURATION CALCULATION AND CACHING
# ============================================================================

# Calculate total duration of a playlist with improved caching
get_playlist_duration() {
    local playlist_file="$1"
    local source_dir="${2:-}"
    local use_cache="${3:-true}"

    if [[ ! -f "$playlist_file" ]]; then
        echo "0 0"
        return
    fi

    # Quick file count check
    local file_count
    file_count=$(grep -c "^file " "$playlist_file" 2>/dev/null || echo 0)
    
    # Generate cache key based on source directory and file count
    local cache_key
    cache_key=$(echo "${source_dir}:${file_count}" | md5sum 2>/dev/null | cut -d' ' -f1 || echo "${source_dir}_${file_count}")
    
    # Try to retrieve from cache
    if [[ "$use_cache" == "true" && -f "$DURATION_CACHE" ]]; then
        local cached_line
        cached_line=$(grep "^${cache_key}:" "$DURATION_CACHE" 2>/dev/null | grep " ${file_count}$" || true)
        if [[ -n "$cached_line" ]]; then
            log_debug "Cache hit for $(basename "$source_dir") (${file_count} files)"
            echo "$cached_line" | cut -d':' -f2-
            return
        fi
    fi
    
    # Cache miss - need to calculate
    log "INF" "Calculating durations for $(basename "$source_dir") (${file_count} files)..."

    local playlist_dir
    playlist_dir=$(dirname "$playlist_file")

    # Parse durations from playlist comments first (if available)
    local total_duration=0
    local files_with_duration=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ ^file\ \'([^\']+)\'\ #\ duration:\ ([0-9.]+) ]]; then
            local duration="${BASH_REMATCH[2]}"
            if [[ -n "$duration" && "$duration" != "0" ]]; then
                total_duration=$(awk -v sum="$total_duration" -v dur="$duration" 'BEGIN { printf "%.6f", sum + dur }')
                files_with_duration=$((files_with_duration + 1))
            fi
        fi
    done < "$playlist_file"
    
    # If all files had durations in comments, we're done
    if [[ $files_with_duration -eq $file_count ]]; then
        local result="${total_duration} ${file_count}"
        
        # Cache the result
        if [[ "$use_cache" == "true" ]]; then
            mkdir -p "$(dirname "$DURATION_CACHE")"
            grep -v "^${cache_key}:" "$DURATION_CACHE" 2>/dev/null > "${DURATION_CACHE}.tmp" || true
            echo "${cache_key}:${result}" >> "${DURATION_CACHE}.tmp"
            mv "${DURATION_CACHE}.tmp" "$DURATION_CACHE" 2>/dev/null || true
        fi
        
        echo "$result"
        return
    fi
    
    # Fallback: Need to probe files that don't have duration comments
    log "WAR" "Some files missing duration metadata, probing with ffprobe..."
    
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

    # Validate the result format
    if ! echo "$result" | grep -qE '^[0-9]+(\.[0-9]+)? [0-9]+$'; then
        log "WAR" "Invalid duration result for $playlist_file, using 0"
        result="0 0"
    fi

    # Cache the result
    if [[ "$use_cache" == "true" ]]; then
        mkdir -p "$(dirname "$DURATION_CACHE")"
        grep -v "^${cache_key}:" "$DURATION_CACHE" 2>/dev/null > "${DURATION_CACHE}.tmp" || true
        echo "${cache_key}:${result}" >> "${DURATION_CACHE}.tmp"
        mv "${DURATION_CACHE}.tmp" "$DURATION_CACHE" 2>/dev/null || true
    fi

    echo "$result"
}

# ============================================================================
# PLAYLIST GENERATION
# ============================================================================

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
            # For video files, add duration as a comment on the same line
            if [[ "$media_type" == "Video" ]]; then
                local duration
                duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || echo "0")
                # Validate and format duration
                if [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
                    echo "file '$file' # duration: $duration"
                else
                    echo "file '$file' # duration: 0"
                fi
            else
                echo "file '$file'"
            fi
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

# ============================================================================
# PROGRESS MONITORING
# ============================================================================

# Helper to parse progress output
parse_progress_output() {
    local output="$1"
    local file_ext_regex="$2"

    # Filter out the concatenated music file
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
      | grep -Eo '[0-9]+(\.[0-9]+)?%' \
      | head -n 1 || true)"

    echo "$current_file|$progress_percent"
}

# Get file info from playlist (avoids repeated grep)
get_file_info_from_playlist() {
    local current_file="$1"
    local playlist_file="$2"
    
    # Use awk for single-pass parsing (compatible with mawk and gawk)
    awk -v target="$current_file" '
        BEGIN { line_num = 0; total = 0; found = 0; duration = "" }
        /^file / { 
            total++; 
            if ($0 ~ target) { 
                line_num = total; 
                found = 1;
                # Extract duration from comment using sub/gsub
                if ($0 ~ /# duration: [0-9.]+/) {
                    temp = $0;
                    sub(/.*# duration: /, "", temp);
                    sub(/ .*/, "", temp);
                    duration = temp;
                }
            }
        }
        END { 
            if (found) {
                print line_num " " total " " duration;
            }
        }
    ' "$playlist_file"
}

# Function to monitor ffmpeg using the 'progress' command in the background
monitor_ffmpeg_progress() {
    local last_logged_file=""
    
    # Persist last file even if we are killed (TERM/INT) or exit normally.
    persist_last_played() {
        if [[ -n "$last_logged_file" ]]; then
            echo "$last_logged_file" > "${LAST_PLAYED_FILE}"
            LAST_LOGGED_FILE="$last_logged_file"
        fi
        # Print a final newline when monitoring stops
        >&2 echo
    }
    trap persist_last_played EXIT TERM INT

    # Give ffmpeg a moment to start and open a file before we start monitoring
    sleep 3

    # Pre-calculate file extension regex once
    local sanitized_types="${VIDEO_FILE_TYPES%\"}"
    sanitized_types="${sanitized_types#\"}"
    sanitized_types="${sanitized_types%\'}"
    sanitized_types="${sanitized_types#\'}"
    local file_ext_regex
    file_ext_regex="$(printf '%s\n' "$sanitized_types" | paste -sd'|' -)"

    # Monitor loop with reduced overhead
    while pidof -x ffmpeg >/dev/null 2>&1; do
        # Take a snapshot; don't let a transient error kill the loop
        local output
        output="$(progress -c ffmpeg -q 2>/dev/null || true)"
        if [[ -z "$output" ]]; then
            sleep 2
            continue
        fi

        # Parse output using helper
        local result
        result=$(parse_progress_output "$output" "$file_ext_regex")
        local current_file="${result%%|*}"
        local progress_percent="${result##*|}"

        if [[ -n "$current_file" && "$current_file" != "$last_logged_file" ]]; then
            # Optimized: Get all file info in one call
            local file_info
            file_info=$(get_file_info_from_playlist "$current_file" "$VIDEO_PLAYLIST")
            
            if [[ -n "$file_info" ]]; then
                read -r line_num total_files duration <<< "$file_info"
                local file_counter_str="|${line_num}/${total_files}]"
                local file_duration=""
                
                if [[ -n "$duration" && "$duration" != "0" ]]; then
                    file_duration=$(format_duration "$duration")
                fi
                
                if [[ -n "$file_duration" ]]; then
                    log "VID" "▶ [${LOOP_COUNT}${file_counter_str} $(basename "$current_file") (${progress_percent:-0.0%}) ⏱ ${file_duration}"
                else
                    log "VID" "▶ [${LOOP_COUNT}${file_counter_str} $(basename "$current_file") (${progress_percent:-0.0%})"
                fi
            else
                log "VID" "▶ [${LOOP_COUNT}] $(basename "$current_file") (${progress_percent:-0.0%})"
            fi
            
            last_logged_file="$current_file"
            echo "$last_logged_file" > "${LAST_PLAYED_FILE}"
            LAST_LOGGED_FILE="$last_logged_file"
            
        elif [[ "${ENABLE_PROGRESS_UPDATES}" == "true" && -n "$current_file" && -n "$progress_percent" ]]; then
            log "VID" "Progress: $(basename "$current_file") (${progress_percent})" "-n"
        fi

        sleep 1
    done

    # Final persistence
    if [[ -n "$last_logged_file" ]]; then
        echo "$last_logged_file" > "${LAST_PLAYED_FILE}"
        LAST_LOGGED_FILE="$last_logged_file"
    fi
    >&2 echo
}

# ============================================================================
# AUDIO AND VIDEO CONFIGURATION
# ============================================================================

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
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and map filtered video and music audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]" -map "[vout]" -map "1:a")
            else
                args+=(-map 0:v -map "1:a") # Map video and music audio directly
            fi
            args+=(-c:a copy)
        else
            log "MUS" "Applying music volume (${music_volume}). Audio will be re-encoded."
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and adjust music volume and map filtered video and adjusted music audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];[1:a]volume=${music_volume},asetpts=PTS-STARTPTS[aud]" -map "[vout]" -map "[aud]")
            else
                # Adjust music volume and map video and adjusted music audio
                args+=(-filter_complex "[1:a]volume=${music_volume},asetpts=PTS-STARTPTS[aud]" -map 0:v -map "[aud]")
            fi
            args+=(-c:a aac -ar "${AUDIO_SAMPLE_RATE}" -b:a "${audio_bitrate}")
        fi
        args+=(-shortest) # End stream when the video playlist finishes
    else
        log "VID" "Music is disabled. Using video audio directly. Video filter: ${use_video_filter}"
        # Check if the first video has audio before copying
        local first_video
        first_video=$(grep -m1 "^file " "$VIDEO_PLAYLIST" | sed "s/^file '\(.*\)'/\1/" || true)

        if [[ -n "$first_video" ]] && has_audio_stream "$first_video"; then
            log "VID" "Copying audio stream without re-encoding (-c:a copy)."
            if [[ "$use_video_filter" == "true" ]]; then
                # Apply video filter and map filtered video and original audio
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]" -map "[vout]" -map "0:a?")
            else
                args+=(-map 0:v -map "0:a?") # Map video and audio directly (? makes it optional)
            fi
            args+=(-c:a copy)
        else
            log "WAR" "Video has no audio stream. Encoding silent audio."
            if [[ "$use_video_filter" == "true" ]]; then
                args+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];anullsrc=r=${AUDIO_SAMPLE_RATE}:cl=stereo[aud]" -map "[vout]" -map "[aud]")
            else
                args+=(-f lavfi -i "anullsrc=r=${AUDIO_SAMPLE_RATE}:cl=stereo" -map 0:v -map 1:a)
            fi
            args+=(-c:a aac -ar "${AUDIO_SAMPLE_RATE}" -ac 2 -b:a "${audio_bitrate}")
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
             #-idr_interval 1                # Insert IDR frames at every keyframe
             -compression_level 1           # Lower = better quality, more GPU work (0-7, default 4)
             -quality 1                     # VAAPI quality hint, lower = better
             -aud 1                         # Insert Access Unit Delimiter
             -sei timing+recovery_point     # Insert SEI messages for timing and recovery points
             -async_depth 4                 # Audio sync depth
             -coder cabac                   # Use CABAC entropy coding
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
             -tune zerolatency              # Reduce encoder buffer latency, good for live streams
             -profile:v high                # High profile (matches VA-API branch for consistency)
             -r "${STREAM_FRAMERATE}"       # Set frame rate
             -fps_mode cfr                  # Constant frame rate
             -b:v "${VIDEO_BITRATE}"        # Target bitrate
             -minrate "${VIDEO_BITRATE}"    # Set minimum bitrate
             -maxrate "${VIDEO_BITRATE}"    # Set maximum bitrate
             -bufsize "${BUFSIZE}"          # Set buffer size
             -g "${GOP_SIZE}"               # Set GOP size
             -keyint_min "${GOP_SIZE}"      # Set minimum GOP size
             -sc_threshold 0                # Disable scene-change detection so GOP stays fixed
             )
    fi
    CODEC_ARGS=("${args[@]}")
}

# ============================================================================
# ERROR DETECTION
# ============================================================================

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

# ============================================================================
# FFMPEG STREAM MANAGEMENT
# ============================================================================

# Helper to format command arguments for logging (adds quotes if needed)
format_cmd_for_log() {
    local cmd_str=""
    for arg in "$@"; do
        if [[ "$arg" =~ [[:space:]] ]] || [[ "$arg" == *"["* ]] || [[ "$arg" == *"]"* ]]; then
            cmd_str+=" \"$arg\""
        else
            cmd_str+=" $arg"
        fi
    done
    echo "$cmd_str"
}

# Function to start the ffmpeg stream with dynamically constructed arguments
start_ffmpeg_stream() {
    log "VID" "Preparing to start FFmpeg stream..."

    local -a cmd
    cmd=(ffmpeg "${FFMPEG_OPTS[@]}" "${VAAPI_OPTS[@]}")

    # --- Input Configuration ---
    cmd+=(-re -f concat -safe 0 -i "$1")

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
        local cmd_str
        cmd_str=$(format_cmd_for_log "${cmd[@]}")
        log_debug "Executing FFmpeg command (logging to ${FFMPEG_LOG_FILE}): ${cmd_str}"
        # Run ffmpeg in the background to get its PID, redirecting logs to a file.
        "${cmd[@]}" >> "$FFMPEG_LOG_FILE" 2>&1 &
    else
        cmd+=(-loglevel warning) # Set ffmpeg log level
        local cmd_str
        cmd_str=$(format_cmd_for_log "${cmd[@]}")
        log_debug "Executing FFmpeg command: ${cmd_str}"
        # If script logging is enabled, pipe ffmpeg's stderr through `tee` to
        # simultaneously print to the console and append to the script log file.
        # Otherwise, just run ffmpeg and let its stderr go to the console directly.
        if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
            "${cmd[@]}" >/dev/null 2> >(tee -a "${SCRIPT_LOG_FILE}" >&2) &
        else
            "${cmd[@]}" 2>&1 &
        fi
    fi

    local ffmpeg_pid=$!
    FFMPEG_PID=$ffmpeg_pid
    local monitor_pid=""

    # Start the progress monitor in the background if the command exists
    if command -v progress &> /dev/null; then
        log "INF" "Starting 'progress' monitor for the 'ffmpeg' command."
        monitor_ffmpeg_progress &
        monitor_pid=$!
        MONITOR_PID=$monitor_pid
    fi

    # Use 'wait' to block the script until the ffmpeg process completes.
    # This makes ffmpeg behave like a foreground process for the main script loop.
    wait "$ffmpeg_pid"
    local exit_code=$?

    # Clean up the background monitor process when ffmpeg is done
    if [[ -n "$monitor_pid" ]]; then
        # Give the monitor time to detect ffmpeg exit and flush the last file
        for _ in 1 2 3; do
            kill -0 "$monitor_pid" 2>/dev/null || break
            sleep 1
        done
        wait "$monitor_pid" 2>/dev/null || true
        
        # Read the last played file from the temp file
        local last_played_file=""
        if [[ -f "${LAST_PLAYED_FILE}" ]]; then
            last_played_file=$(<"${LAST_PLAYED_FILE}")
        fi

        # If we know the last file, log its context in the playlist
        if [[ -n "$last_played_file" ]]; then
            local playlist_file="$1"
            # Use optimized function to get file info
            local file_info
            file_info=$(get_file_info_from_playlist "$last_played_file" "$playlist_file")
            
            if [[ -n "$file_info" ]]; then
                read -r line_num total_files duration <<< "$file_info"
                log "ERR" "Last Played: $(basename "$last_played_file") (File ${line_num}/${total_files})"

                # Log the next file if it exists
                if [[ "$line_num" -lt "$total_files" ]]; then
                    local next_line_num=$((line_num + 1))
                    local next_file_line
                    next_file_line=$(sed -n "${next_line_num}p" "$playlist_file")
                    # Extract just the filename from the playlist line
                    local next_file
                    next_file=$(echo "$next_file_line" | sed -n "s/^file '\([^']*\)'.*$/\1/p")
                    if [[ -n "$next_file" ]]; then
                        log "ERR" "  ->   Next: $(basename "$next_file")"
                    fi
                fi
            fi
        fi
    fi

    # Save state after stream ends
    save_stream_state

    # Return the exit code of ffmpeg
    return $exit_code
}

# ============================================================================
# SYSTEM INFORMATION GATHERING
# ============================================================================

# Gather system information in separate function
gather_system_info() {
    local -A sys_info
    
    # Linux Distribution
    if [[ -f /etc/os-release ]]; then
        sys_info[linux]=$(source /etc/os-release 2>/dev/null && echo "${NAME} ${VERSION_ID:-}" || echo "Linux (unknown)")
    else
        sys_info[linux]="Linux (unknown)"
    fi
    
    # CPU Detection
    if [[ -f /proc/cpuinfo ]]; then
        local cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^[ \t]*//' || echo "")
        local cpu_cores=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "0")
        if [[ -n "$cpu_model" && "$cpu_cores" -gt 0 ]]; then
            sys_info[cpu]="${cpu_model} (${cpu_cores} cores)"
        elif [[ -n "$cpu_model" ]]; then
            sys_info[cpu]="$cpu_model"
        else
            sys_info[cpu]="unknown"
        fi
    else
        sys_info[cpu]="unknown"
    fi
    
    # GPU Detection (VA-API)
    if [[ -e "$VAAPI_DEVICE" ]] && command -v vainfo &> /dev/null; then
        local vainfo_output=$(vainfo --display drm --device "$VAAPI_DEVICE" 2>&1 || true)
        
        # Extract VA-API version
        local vaapi_line=$(echo "$vainfo_output" | grep -i "VA-API version:" | head -n1 || echo "")
        sys_info[vaapi]=$(echo "$vaapi_line" | sed 's/.*VA-API version: //' | sed 's/^[ \t]*//')

        # Extract Driver version
        local driver_line=$(echo "$vainfo_output" | grep -i "Driver version:" | head -n1 || echo "")
        sys_info[driver]=$(echo "$driver_line" | sed 's/.*Driver version: //' | sed 's/^[ \t]*//' | sed 's/ ()$//')
    else
        sys_info[vaapi]="not detected"
        sys_info[driver]="not detected"
    fi
    
    [[ -z "${sys_info[vaapi]}" ]] && sys_info[vaapi]="unknown"
    [[ -z "${sys_info[driver]}" ]] && sys_info[driver]="unknown"
    
    # FFmpeg version
    if command -v ffmpeg &> /dev/null; then
        sys_info[ffmpeg]=$(ffmpeg -version 2>/dev/null | head -n1 | sed 's/ffmpeg version //' | awk '{print $1}' || echo "unknown")
    else
        sys_info[ffmpeg]="not installed"
    fi
    
    # FFprobe version
    if command -v ffprobe &> /dev/null; then
        sys_info[ffprobe]=$(ffprobe -version 2>/dev/null | head -n1 | sed 's/ffprobe version //' | awk '{print $1}' || echo "unknown")
    else
        sys_info[ffprobe]="not installed"
    fi
    
    # Progress command version
    if command -v progress &> /dev/null; then
        sys_info[progress]=$(progress -v 2>/dev/null | head -n1 | sed 's/progress version //' | awk '{print $1}' || echo "unknown")
    else
        sys_info[progress]="not installed"
    fi
    
    # Return associative array as serialized string
    for key in "${!sys_info[@]}"; do
        echo "${key}=${sys_info[$key]}"
    done
}

# ============================================================================
# CONFIGURATION DISPLAY
# ============================================================================

# Display configuration in a cleaner function
display_configuration() {
    local -A sys_info
    
    # Parse system info
    while IFS='=' read -r key value; do
        sys_info[$key]="$value"
    done < <(gather_system_info)
    
    log "WAR" "=== STREAM SCRIPT START ==="

    # Helper to calculate max length from a list of strings
    get_max_len() {
        printf "%s\n" "$@" | awk '{ if (length($0) > max) max = length($0) } END { print max }'
    }

    # Define all values first to measure them
    local v_source=": $VIDEO_PLAYLIST"
    local v_res=": $STREAM_RESOLUTION"
    local v_fps=": ${STREAM_FRAMERATE}fps"
    local v_bit=": $VIDEO_BITRATE"
    local v_gop=": $GOP_SIZE (2s)"
    local v_buf=": $BUFSIZE"
    local v_hw=": $USE_HWACCEL"
    local v_dev=": $VAAPI_DEVICE"
    
    local v_abit=": $AUDIO_BITRATE"
    local v_music=": $ENABLE_MUSIC"
    local v_loop=": $ENABLE_LOOP"
    local v_shuf=": ${ENABLE_SHUFFLE:-false}"
    
    local v_linux=": ${sys_info[linux]}"
    local v_cpu=": ${sys_info[cpu]}"
    local v_vaapi=": ${sys_info[vaapi]}"
    local v_driver=": ${sys_info[driver]}"
    local v_ffmpeg=": ${sys_info[ffmpeg]}"
    local v_ffprobe=": ${sys_info[ffprobe]}"
    local v_progress=": ${sys_info[progress]}"
    
    # Calculate dynamic widths
    local max_l_val_len
    if [[ "$USE_HWACCEL" == "true" ]]; then
        max_l_val_len=$(get_max_len "$v_source" "$v_res" "$v_fps" "$v_bit" "$v_gop" "$v_buf" "$v_hw" "$v_dev")
    else
        max_l_val_len=$(get_max_len "$v_source" "$v_res" "$v_fps" "$v_bit" "$v_gop" "$v_buf" "$v_hw")
    fi
    local L_WIDTH=$((max_l_val_len + 14))
    [[ $L_WIDTH -lt 20 ]] && L_WIDTH=20

    local max_r_val_len
    max_r_val_len=$(get_max_len "$v_abit" "$v_music" "$v_loop" "$v_shuf")
    local R_WIDTH=$((max_r_val_len + 16))
    [[ $R_WIDTH -lt 15 ]] && R_WIDTH=15

    # Ensure FULL_WIDTH is enough for system info
    local max_sys_len
    max_sys_len=$(get_max_len "$v_linux" "$v_cpu" "$v_vaapi" "$v_driver" "$v_ffmpeg" "$v_ffprobe" "$v_progress")
    local min_full_width=$((max_sys_len + 14))
    if [[ $((L_WIDTH + R_WIDTH + 3)) -lt $min_full_width ]]; then
        local diff=$((min_full_width - (L_WIDTH + R_WIDTH + 3)))
        L_WIDTH=$((L_WIDTH + (diff / 2) + (diff % 2)))
        R_WIDTH=$((R_WIDTH + (diff / 2)))
    fi

    local FULL_WIDTH=$((L_WIDTH + R_WIDTH + 3))
    
    # Unicode box characters
    local V="│"
    local H="─"
    local HH="═"
    local TT="╤"
    
    # Helper to simplify printing a 2-column row
    print_2col() {
        local l_text="$1"
        local r_text="$2"
        log "SET" "$V $l_text $V $r_text $V"
    }

    # Prepare Values with padded strings
    local val_source=$(pad_str "$v_source" $((L_WIDTH-14)))
    local val_res=$(pad_str "$v_res" $((L_WIDTH-14)))
    local val_fps=$(pad_str "$v_fps" $((L_WIDTH-14)))
    local val_bit=$(pad_str "$v_bit" $((L_WIDTH-14)))
    local val_gop=$(pad_str "$v_gop" $((L_WIDTH-14)))
    local val_buf=$(pad_str "$v_buf" $((L_WIDTH-14)))
    local val_hw=$(pad_str "$v_hw" $((L_WIDTH-14)))
    local val_dev=$(pad_str "$v_dev" $((L_WIDTH-14)))
    local val_empty_l=$(pad_str "" $((L_WIDTH)))

    local val_abit=$(pad_str "$v_abit" $((R_WIDTH-16)))
    local val_music=$(pad_str "$v_music" $((R_WIDTH-16)))
    local val_loop=$(pad_str "$v_loop" $((R_WIDTH-16)))
    local val_shuf=$(pad_str "$v_shuf" $((R_WIDTH-16)))
    local val_empty_r=$(pad_str "" $((R_WIDTH)))

    # Draw System Configuration (Top Section)
    log "SET" "╒$(draw_line 3 "$HH") System Configuration $(draw_line $((FULL_WIDTH - 23)) "$HH")╕"
    local val_linux=$(pad_str "$v_linux" $((FULL_WIDTH - 14)))
    local val_cpu=$(pad_str "$v_cpu" $((FULL_WIDTH - 14)))
    local val_vaapi=$(pad_str "$v_vaapi" $((FULL_WIDTH - 14)))
    local val_driver=$(pad_str "$v_driver" $((FULL_WIDTH - 14)))
    local val_ffmpeg=$(pad_str "$v_ffmpeg" $((FULL_WIDTH - 14)))
    local val_ffprobe=$(pad_str "$v_ffprobe" $((FULL_WIDTH - 14)))
    local val_progress=$(pad_str "$v_progress" $((FULL_WIDTH - 14)))
    log "SET" "$V $(printf "%-13s %s" "Linux" "$val_linux") $V"
    log "SET" "$V $(printf "%-13s %s" "CPU" "$val_cpu") $V"
    log "SET" "$V $(printf "%-13s %s" "VA-API" "$val_vaapi") $V"
    log "SET" "$V $(printf "%-13s %s" "Driver" "$val_driver") $V"
    log "SET" "$V $(printf "%-13s %s" "ffmpeg" "$val_ffmpeg") $V"
    log "SET" "$V $(printf "%-13s %s" "ffprobe" "$val_ffprobe") $V"
    log "SET" "$V $(printf "%-13s %s" "progress" "$val_progress") $V"

    # Draw Video/Audio Configuration
    local header_l="╞$(draw_line 3 "$HH") Video Configuration $(draw_line $((L_WIDTH - 22)) "$HH")"
    local header_r="$(draw_line 1 "$HH") Audio Configuration $(draw_line $((R_WIDTH - 20)) "$HH")╡"
    log "SET" "${header_l}${TT}${header_r}"

    print_2col "$(printf "%-13s %s" "Source" "$val_source")" "$(printf "%-15s %s" "Audio Bitrate" "$val_abit")"
    print_2col "$(printf "%-13s %s" "Resolution" "$val_res")" "$(printf "%-15s %s" "Music Enabled" "$val_music")"
    print_2col "$(printf "%-13s %s" "Framerate" "$val_fps")" "$val_empty_r"
    print_2col "$(printf "%-13s %s" "Bitrate" "$val_bit")" "$val_empty_r"

    # Split header for Loop & Shuffle
    local mid_r="╞$(draw_line 1 "$HH") Loop & Shuffle $(draw_line $((R_WIDTH - 15)) "$HH")╡"
    log "SET" "$V $(printf "%-13s %s" "GOP Size" "$val_gop") $mid_r"

    print_2col "$(printf "%-13s %s" "Buffer Size" "$val_buf")" "$(printf "%-15s %s" "Loop Enabled" "$val_loop")"
    print_2col "$(printf "%-13s %s" "HW Accel" "$val_hw")" "$(printf "%-15s %s" "Shuffle Enabled" "$val_shuf")"

    if [[ "$USE_HWACCEL" == "true" ]]; then
        print_2col "$(printf "%-13s %s" "VA-API Device" "$val_dev")" "$val_empty_r"
    else
        print_2col "$val_empty_l" "$val_empty_r"
    fi

    # Draw Stream Destination
    log "SET" "╞$(draw_line 3 "$HH") Stream Destination $(draw_line $((L_WIDTH - 21)) "$HH")╧$(draw_line $((R_WIDTH + 2)) "$HH")╡"
    local val_url=$(pad_str ": $TWITCH_URL" $((FULL_WIDTH - 14)))
    log "SET" "$V $(printf "%-13s %s" "URL" "$val_url") $V"

    # Draw Logging
    log "SET" "╞$(draw_line 3 "$HH") Logging $(draw_line $((FULL_WIDTH - 10)) "$HH")╡"
    local val_flog=$(pad_str ": $FFMPEG_LOG_FILE (enabled: $ENABLE_FFMPEG_LOG_FILE)" $((FULL_WIDTH - 14)))
    local val_lvl=$(pad_str ": $FFMPEG_LOG_LEVEL" $((FULL_WIDTH - 14)))
    log "SET" "$V $(printf "%-13s %s" "FFmpeg Log" "$val_flog") $V"
    if [[ -n "$FFMPEG_LOG_LEVEL" ]]; then
        log "SET" "$V $(printf "%-13s %s" "Log Level" "$val_lvl") $V"
    fi
    log "SET" "└$(draw_line $((FULL_WIDTH + 2)) "$H")┘"
}

# ============================================================================
# MAIN FUNCTION
# ============================================================================

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

    # Record the overall session start time (once, not reset per ffmpeg run)
    STREAM_START_TIME=$(date +%s)

    # Initialize duration cache
    mkdir -p "$(dirname "$DURATION_CACHE")"
    touch "$DURATION_CACHE" 2>/dev/null || true

    # Load previous state if available
    load_stream_state

    # Display system and stream configuration
    display_configuration

    # Initial wait for the video playlist to be generated
    generate_videolist

    # Main stream loop
    while true; do
        LOOP_COUNT=$((LOOP_COUNT + 1))
        log "WAR" "=== STREAMING LOOP START [${LOOP_COUNT}] ==="

        # --- Stream state summary (console) ---
        # Sync LAST_LOGGED_FILE from disk in case a previous loop wrote it via the monitor.
        if [[ -f "${LAST_PLAYED_FILE}" ]]; then
            local _lp_state
            _lp_state=$(<"${LAST_PLAYED_FILE}")
            [[ -n "$_lp_state" ]] && LAST_LOGGED_FILE="$_lp_state"
        fi
        if [[ -n "${LAST_LOGGED_FILE:-}" ]]; then
            log "WAR" "  Last played   : $(basename "$LAST_LOGGED_FILE")"
        else
            log "WAR" "  Last played   : (none — first run)"
        fi
        if [[ -n "${STREAM_START_TIME:-}" ]]; then
            local _elapsed=$(( $(date +%s) - STREAM_START_TIME ))
            local _started
            _started=$(date -d "@${STREAM_START_TIME}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || date -r "${STREAM_START_TIME}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
                    || echo "unknown")
            log "WAR" "  Session uptime: $(format_duration "$_elapsed") (since ${_started})"
        fi

        # If shuffle is enabled, regenerate the video playlist on each loop.
        if [[ "${ENABLE_SHUFFLE:-false}" == "true" && $LOOP_COUNT -gt 1 ]]; then
            generate_videolist
        fi

        # Generate/Shuffle Music Playlist
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

        # Launch FFmpeg with retry logic for network errors
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

        # Loop Control
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

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

# Launch the main logic
main
