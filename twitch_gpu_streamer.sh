#!/bin/bash

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

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

# VIDEO_DIR is set in docker-compose (e.g. /videos). Allow an explicit VIDEO_PLAYLIST to override.
VIDEO_DIR="${VIDEO_DIR:-/videos}"
VIDEO_FILE_TYPES="${VIDEO_FILE_TYPES:-mp4 mkv mov avi webm flv}"
# Path for the generated video playlist
VIDEO_PLAYLIST="${VIDEO_PLAYLIST:-$LOG_DIR/video_list.txt}"

# Optional background music playlist (concat format)
MUSIC_DIR="${MUSIC_DIR:-/music}"
MUSIC_LIST="${MUSIC_LIST:-$LOG_DIR/music_list.txt}"
ENABLE_MUSIC="${ENABLE_MUSIC:-false}"
MUSIC_VOLUME="${MUSIC_VOLUME:-0.25}"
MUSIC_FILE_TYPES="${MUSIC_FILE_TYPES:-mp3 flac wav ogg}"

# Streaming resolution & bitrates
STREAM_RESOLUTION="${STREAM_RESOLUTION:-1280x720}"
STREAM_FRAMERATE="${STREAM_FRAMERATE:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-128k}"

# Calculate GOP size for a 2-second keyframe interval, as recommended by Twitch.
GOP_SIZE=$((STREAM_FRAMERATE * 2))

# VA-API device and hardware acceleration toggle
VAAPI_DEVICE="${VAAPI_DEVICE:-/dev/dri/renderD128}"
ENABLE_HW_ACCEL="${ENABLE_HW_ACCEL:-false}"

# Loop and reshuffle control
ENABLE_LOOP="${ENABLE_LOOP:-false}"

# FFmpeg resilience/options and basic flags
FFMPEG_OPTS=(
    -fflags "+discardcorrupt+genpts"   # Drop corrupted frames and generate missing PTS if needed
    -err_detect ignore_err             # Ignore decoding errors
)

# VA-API options only used if enabled and device exists
VAAPI_OPTS=()

# Decide whether to use VA-API or software encoding
if [[ "$ENABLE_HW_ACCEL" == "true" && -e "$VAAPI_DEVICE" ]]; then
    VAAPI_OPTS=(
        -hwaccel vaapi
        -vaapi_device "$VAAPI_DEVICE"
        -hwaccel_output_format vaapi
    )
    USE_HWACCEL=true
else
    USE_HWACCEL=false
fi

# Create a scaled filter for the chosen encoder
if [[ "$USE_HWACCEL" == "true" ]]; then
    VIDEO_FILTER="scale_vaapi=w=${STREAM_RESOLUTION%x*}:h=${STREAM_RESOLUTION#*x}:format=nv12"
else
    VIDEO_FILTER="scale=${STREAM_RESOLUTION%x*}:${STREAM_RESOLUTION#*x}:flags=lanczos"
fi

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
    # Log to stderr for colored console output
    >&2 echo -e "${color}${timestamp} [${level}] ${message}${NC}"

    # Log to file if enabled, without color codes
    if [[ "${ENABLE_SCRIPT_LOG_FILE}" == "true" ]]; then
        echo "${timestamp} [${level}] ${message}" >> "${SCRIPT_LOG_FILE}"
    fi
}

# Function to format seconds into a human-readable string (d h:m:s)
format_duration() {
    local total_seconds=${1%.*} # Use integer part of seconds
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

# Function to calculate total duration of a playlist
get_playlist_duration() {
    local playlist_file="$1"
    local total_duration=0
    local file_count=0

    if [[ ! -f "$playlist_file" ]]; then
        echo "0 0"
        return
    fi

    local playlist_dir
    playlist_dir=$(dirname "$playlist_file")

    # Process the entire playlist file with awk for efficiency and to avoid subshell issues.
    # This is significantly faster than looping in bash and calling external commands for each line.
    awk -v playlist_dir="$playlist_dir" '
        BEGIN { FS = "\x27"; total_duration = 0; file_count = 0; } # Use single quote as field separator
        /^file / {
            file_count++;
            # The file path is the second field when splitting by single quotes
            relative_path = $2;
            # Prepend the playlist directory to form a full path, unless it is already absolute.
            full_path = (relative_path ~ /^\//) ? relative_path : playlist_dir "/" relative_path;
            
            # Use ffprobe to get the duration for all file types.
            cmd = "ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 \"" full_path "\"";
            if ((cmd | getline duration) > 0) {
                total_duration += duration;
            }
            close(cmd);
        }
        END { printf "%.6f %d\n", total_duration, file_count; }
    ' "$playlist_file"
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
        > "${output_file}"
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
    
    local count=$(grep -c "^file " "${output_file}" 2>/dev/null || echo 0)
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
    local count=$(grep -c "^file " "${MUSIC_LIST}" 2>/dev/null || echo 0)
    if [[ $count -eq 0 ]]; then
        log "WAR" "Found no music files under $MUSIC_DIR - disabling music."
        ENABLE_MUSIC="false"
        rm -f "$MUSIC_LIST"
    else
        # Log music playlist duration
        local duration_info
        duration_info=$(get_playlist_duration "$MUSIC_LIST")
        local formatted_duration=$(format_duration "$(echo "$duration_info" | cut -d' ' -f1)")
        log "WAR" "Music playlist duration: ${formatted_duration} - $(echo "$duration_info" | cut -d' ' -f2) files"
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


# Function to start the ffmpeg stream with dynamically constructed arguments
start_ffmpeg_stream() {
    log "VID" "Preparing to start FFmpeg stream..."

    local -a cmd
    cmd=(ffmpeg "${FFMPEG_OPTS[@]}" "${VAAPI_OPTS[@]}")

    # --- Input Configuration ---
    cmd+=(-re -f concat -safe 0 -i "$1") # Use the playlist path passed as an argument

    # --- Music and Filter Configuration ---
    if [[ "$ENABLE_MUSIC" == "true" && -f "$MUSIC_LIST" ]]; then
        log "MUS" "Music is enabled. Adding music input and filter."
        cmd+=(-stream_loop -1 -f concat -safe 0 -i "$MUSIC_LIST")
        cmd+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];[1:a]volume=${MUSIC_VOLUME},asetpts=PTS-STARTPTS[aud]")
        cmd+=(-map "[vout]" -map "[aud]")
        cmd+=(-shortest) # End stream when the video playlist finishes
    else
        log "VID" "Music is disabled. Using video audio directly."
        cmd+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]")
        cmd+=(-map "[vout]" -map "0:a")
    fi

    # --- Codec Configuration ---
    if [[ "$USE_HWACCEL" == "true" ]]; then
        cmd+=(-c:v h264_vaapi -profile:v high -b:v "${VIDEO_BITRATE}" -r "${STREAM_FRAMERATE}" -vsync cfr -minrate "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "${VIDEO_BITRATE}" -g "${GOP_SIZE}" -keyint_min "${GOP_SIZE}")
    else
        cmd+=(-c:v libx264 -preset veryfast -b:v "${VIDEO_BITRATE}" -r "${STREAM_FRAMERATE}" -vsync cfr -minrate "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "${VIDEO_BITRATE}" -g "${GOP_SIZE}" -keyint_min "${GOP_SIZE}")
    fi
    cmd+=(-c:a aac -ar 44100 -b:a "${AUDIO_BITRATE}")

    # --- Output Configuration ---
    cmd+=(-f flv "$TWITCH_URL/$STREAM_KEY")

    # --- Logging and Execution ---
    if [[ "$ENABLE_FFMPEG_LOG_FILE" == "true" ]]; then
        # Add verbose logging options only when logging to a file.
        cmd+=(-progress pipe:1 -loglevel info)
        log "VID" "Executing FFmpeg command: ${cmd[*]}"
        # If ffmpeg logging is enabled, redirect its stderr to the specified log file.
        # We also redirect stdout (1) to stderr (2) so the progress report is also logged.
        "${cmd[@]}" >> "$FFMPEG_LOG_FILE" 2>&1
    else
        # Otherwise, keep ffmpeg quiet and discard all output.
        cmd+=(-loglevel error)
        log "VID" "Executing FFmpeg command: ${cmd[*]}"
        # If not enabled, discard stdout but allow stderr (for errors) to print to the console.
        "${cmd[@]}" >/dev/null
    fi
}

main() {
    # Validate mandatory config
    if [[ -z "$STREAM_KEY" || "$STREAM_KEY" == "your_stream_key_here" ]]; then
        log "ERR" "TWITCH_STREAM_KEY is not set. Please add it to your .env or docker-compose and pass it into the container."
        exit 1
    fi

    log "WAR" "=== STREAM SCRIPT START ==="
    log "INF" "Source: $VIDEO_PLAYLIST"
    log "INF" "Resolution: $STREAM_RESOLUTION"
    log "INF" "VA-API Device: $VAAPI_DEVICE"
    log "INF" "TWITCH ingest URL: $TWITCH_URL"
    log "INF" "Framerate: ${STREAM_FRAMERATE}fps, GOP Size: ${GOP_SIZE} (2s keyframe interval)"
    log "INF" "VIDEO bitrate: $VIDEO_BITRATE, AUDIO bitrate: $AUDIO_BITRATE"
    log "INF" "Hardware acceleration: $USE_HWACCEL"
    log "INF" "Music Enabled: $ENABLE_MUSIC"
    log "INF" "Looping Enabled: $ENABLE_LOOP"
    log "INF" "Shuffle Enabled: ${ENABLE_SHUFFLE:-false}"
    log "INF" "FFmpeg log file: $FFMPEG_LOG_FILE (enabled: $ENABLE_FFMPEG_LOG_FILE)"

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
        duration_info=$(get_playlist_duration "$VIDEO_PLAYLIST")
        local total_duration=$(echo "$duration_info" | cut -d' ' -f1)
        local file_count=$(echo "$duration_info" | cut -d' ' -f2)
        log "WAR" "Video playlist duration: $(format_duration "$total_duration") - ${file_count} files"

        # --- Launch FFmpeg ---
        start_ffmpeg_stream "$VIDEO_PLAYLIST"
        
        local exit_code=$?
        log "INF" "FFmpeg process exited with code ${exit_code}."

        # --- Loop Control ---
        if [[ "$ENABLE_LOOP" != "true" ]]; then
            log "WAR" "Looping is disabled. Exiting script."
            break
        fi

        log "INF" "Looping enabled. Restarting stream in 5 seconds..."
        sleep 5
    done
}

#
# --- Main Execution ---
#

# Launch the main logic
main
