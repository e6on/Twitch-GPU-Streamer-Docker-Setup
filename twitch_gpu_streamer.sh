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
MUSIC_FILE_TYPES="${MUSIC_FILE_TYPES:-mp3 flac wav ogg}"

# Streaming resolution & bitrates
STREAM_RESOLUTION="${STREAM_RESOLUTION:-1280x720}"
STREAM_FRAMERATE="${STREAM_FRAMERATE:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-2500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-64k}"

# Calculate GOP size for a 2-second keyframe interval, as recommended by Twitch.
GOP_SIZE=$((STREAM_FRAMERATE * 2))

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
# Show per-file progress percentage updates
ENABLE_PROGRESS_UPDATES="${ENABLE_PROGRESS_UPDATES:-false}"

# FFmpeg resilience/options and basic flags
FFMPEG_OPTS=(
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
        rm -f "$MUSIC_LIST" "$CONCAT_MUSIC_FILE"
    else
        # Log music playlist duration
        local duration_info
        duration_info=$(get_playlist_duration "$MUSIC_LIST")
        local formatted_duration=$(format_duration "$(echo "$duration_info" | cut -d' ' -f1)")
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

  #log "VID" "Progress check 1"

  while pidof -x ffmpeg >/dev/null 2>&1; do
    # Take a snapshot; don't let a transient error kill the loop
    local output
    output="$(progress -c ffmpeg -q 2>/dev/null || true)"
    if [[ -z "$output" ]]; then
      sleep 1
      continue
    fi
    #log "VID" "Progress check 2 output: ${output}"

    # Filter out the concatenated music file; allow 'no difference'
    local filtered_output
    filtered_output="$(echo "$output" | grep -v -- "$CONCAT_MUSIC_FILE" || true)"
    #log "VID" "Progress filtered_output: ${filtered_output}"

    # --- Sanitize VIDEO_FILE_TYPES and build alternation regex ---
    local sanitized_types="${VIDEO_FILE_TYPES%\"}"
    sanitized_types="${sanitized_types#\"}"
    sanitized_types="${sanitized_types%\'}"
    sanitized_types="${sanitized_types#\'}"
    local file_ext_regex
    file_ext_regex="$(printf '%s\n' $sanitized_types | paste -sd'|' -)"
    #log "VID" "File extension regex: ${file_ext_regex}"

    # Extract filename (best-effort)
    local current_file
    current_file="$(echo "$filtered_output" \
      | grep -Eo "(/|\.\/)?[^[:space:]]+\.(${file_ext_regex})" \
      | head -n 1 || true)"
    #log "VID" "Current file: ${current_file}"

    # Extract percent (best-effort)
    local progress_percent
    progress_percent="$(echo "$output" \
      | grep -Eo '^[[:space:]]*[0-9]+(\.[0-9]+)?%' \
      | head -n 1 || true)"
    #log "VID" "Progress percent: ${progress_percent}"

    if [[ -n "$current_file" && "$current_file" != "$last_logged_file" ]]; then
      [[ -n "$last_logged_file" ]] && >&2 echo
      log "VID" "Now Playing: $(basename "$current_file") (${progress_percent:-0.0%})"
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

# Function to start the ffmpeg stream with dynamically constructed arguments
start_ffmpeg_stream() {
    log "VID" "Preparing to start FFmpeg stream..."

    local -a cmd
    cmd=(ffmpeg "${FFMPEG_OPTS[@]}" "${VAAPI_OPTS[@]}")

    # --- Input Configuration ---
    cmd+=(
         -re        # Read input at native frame rate
         -f concat  # Use concat demuxer
         -safe 0    # Allow unsafe file paths
         -i "$1"    # Use the video playlist path passed as an argument
         )

    # --- Music and Filter Configuration ---
    local -a audio_codec_opts
    if [[ "$ENABLE_MUSIC" == "true" && -f "$CONCAT_MUSIC_FILE" ]]; then
        log "MUS" "Music enabled, replacing original video audio. Video filter: ${USE_VIDEO_FILTER}"
        cmd+=(-stream_loop -1 -i "$CONCAT_MUSIC_FILE") # Loop music infinitely

        # Determine if audio needs re-encoding based on volume
        if [[ $(awk -v vol="$MUSIC_VOLUME" 'BEGIN { print (vol == 1.0) }') -eq 1 ]]; then
            log "MUS" "Music volume is 1.0, copying audio stream directly (-c:a copy)."
            audio_codec_opts=(-c:a copy)
            if [[ "$USE_VIDEO_FILTER" == "true" ]]; then
                cmd+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]")   # Apply video filter
                cmd+=(-map "[vout]" -map "1:a")  # Map filtered video and music audio
            else
                cmd+=(-map 0:v -map "1:a")  # Map video and music audio directly
            fi
        else
            log "MUS" "Applying music volume (${MUSIC_VOLUME}). Audio will be re-encoded."
            audio_codec_opts=(-c:a aac -ar 44100 -b:a "${AUDIO_BITRATE}")
            if [[ "$USE_VIDEO_FILTER" == "true" ]]; then
                cmd+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout];[1:a]volume=${MUSIC_VOLUME},asetpts=PTS-STARTPTS[aud]") # Apply video filter and adjust music volume
                cmd+=(-map "[vout]" -map "[aud]") # Map filtered video and adjusted music audio
            else
                cmd+=(-filter_complex "[1:a]volume=${MUSIC_VOLUME},asetpts=PTS-STARTPTS[aud]") # Adjust music volume
                cmd+=(-map 0:v -map "[aud]") # Map video and adjusted music audio
            fi
        fi
        cmd+=(-shortest) # End stream when the video playlist finishes
    else
        log "VID" "Music is disabled. Using video audio directly. Video filter: ${USE_VIDEO_FILTER}"
        log "VID" "Copying audio stream without re-encoding (-c:a copy)."
        audio_codec_opts=(-c:a copy)
        if [[ "$USE_VIDEO_FILTER" == "true" ]]; then
            cmd+=(-filter_complex "[0:v]${VIDEO_FILTER}[vout]") # Apply video filter
            cmd+=(-map "[vout]" -map "0:a") # Map filtered video and original audio
        else
            cmd+=(-map 0:v -map "0:a") # Map video and audio directly
        fi
    fi

    # --- Codec Configuration ---
    if [[ "$USE_HWACCEL" == "true" ]]; then
        cmd+=(
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
        cmd+=(
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
    cmd+=("${audio_codec_opts[@]}")

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
            ( "${cmd[@]}" 2>&1 >/dev/null ) | tee -a "${SCRIPT_LOG_FILE}" &
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
                log "VID" "Last Played: $(basename "$last_played_file") (File ${line_num}/${total_lines})"

                # Log the next file if it exists
                if [[ "$line_num" -lt "$total_lines" ]]; then
                    local next_line_num=$((line_num + 1))
                    local next_file_line=$(sed -n "${next_line_num}p" "$playlist_file")
                    log "VID" "  ->   Next: $(basename "${next_file_line#file \'}")"
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
        duration_info=$(get_playlist_duration "$VIDEO_PLAYLIST")
        local total_duration=$(echo "$duration_info" | cut -d' ' -f1)
        local file_count=$(echo "$duration_info" | cut -d' ' -f2)
        log "WAR" "Video playlist duration: $(format_duration "$total_duration") - ${file_count} files"

        # --- Launch FFmpeg ---
        # With 'set -e', a non-zero from start_ffmpeg_stream would kill the script.
        # Temporarily disable -e so we can capture the exit code and continue.
        set +e
        start_ffmpeg_stream "$VIDEO_PLAYLIST"
        local exit_code=$?
        set -e
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

# --- Main Execution ---
# Launch the main logic
main
