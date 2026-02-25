# Twitch GPU Streamer Docker Setup

A robust, production-ready Docker setup for streaming video content to Twitch with full VA-API GPU acceleration. Run your entire 24/7 streaming setup in a container with automatic playlist management, hardware encoding, and background music support.

## Features

- ✅ **Hardware Acceleration** - VA-API support for Intel/AMD GPUs with efficient H.264 encoding
- 🎵 **Background Music** - Optional looping audio track with volume control
- 🔄 **Playlist Management** - Automatic video/music playlist generation with shuffle support
- 📊 **Progress Monitoring** - Real-time file playback tracking and progress updates
- 🔁 **Loop & Shuffle** - Continuous streaming with configurable playlist randomization
- 📝 **Advanced Logging** - Structured logging with optional FFmpeg debug output
- 🎛️ **Flexible Configuration** - Comprehensive environment variable controls
- 🐳 **Docker Native** - Fully containerized with minimal host dependencies

## Prerequisites

- **Docker** and **Docker Compose** installed
- **GPU with VA-API support** (Intel/AMD) for hardware acceleration (optional but recommended)
- **Twitch account** with stream key
- **FFmpeg binary** - Download from [BtbN FFmpeg Builds](https://github.com/BtbN/FFmpeg-Builds/releases) — use `ffmpeg-master-latest-linux64-gpl.tar.xz` or a versioned `linux64-gpl` build (n8.0.1 or newer recommended). **Do not use arm64 builds on x86 hosts.**
- **Video files** in supported formats (MP4, MKV, MOV, AVI, WebM, FLV)

## Configuration

All configuration is done through environment variables in the `.env` file or `docker-compose.yaml`.

### Required Settings

| Variable | Description | Example |
|----------|-------------|---------|
| `TWITCH_STREAM_KEY` | Your Twitch stream key | `live_123456789_abc...` |

### Stream Quality Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `STREAM_RESOLUTION` | `1280x720` | Output resolution (720p, 1080p, etc.) |
| `STREAM_FRAMERATE` | `30` | Frames per second (24, 30, 60) |
| `VIDEO_BITRATE` | `2500k` | Video bitrate (higher = better quality) |
| `AUDIO_BITRATE` | `64k` | Audio bitrate |

### Hardware Acceleration

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_HW_ACCEL` | `false` | Enable VA-API GPU acceleration |
| `VAAPI_DEVICE` | `/dev/dri/renderD128` | VA-API device path |
| `USE_VIDEO_FILTER` | `true` | Apply scaling filter (disable for passthrough) |

**Tip:** If your source files are already at your target resolution and framerate, set `USE_VIDEO_FILTER=false` to skip the scaling filter entirely. This results in a simpler, more stable pipeline — especially important for VA-API (see Known Issues below).

### Playlist Options

| Variable | Default | Description |
|----------|---------|-------------|
| `VIDEO_DIR` | `/videos` | Video source directory |
| `VIDEO_FILE_TYPES` | `mp4 mkv mov avi webm flv` | Supported video formats |
| `ENABLE_LOOP` | `false` | Loop playlist indefinitely |
| `LOOP_RESTART_DELAY` | `5` | Delay in seconds before restarting stream after a loop (0 = instant restart) |
| `ENABLE_SHUFFLE` | `false` | Randomize playlist order |

### Background Music

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_MUSIC` | `false` | Enable background music track |
| `MUSIC_DIR` | `/music` | Music source directory |
| `MUSIC_FILE_TYPES` | `mp3 flac wav ogg` | Supported audio formats |
| `MUSIC_VOLUME` | `1.0` | Music volume (0.5 = 50%, 1.5 = 150%) |

**Tip:** Pre-normalize your music files to a consistent loudness level using the included `mp3_to_m4a_with_normalize.sh` script. This converts and normalizes to EBU R128 standard and outputs `.m4a` files at 44100Hz which avoids any sample rate mismatch with the RTMP output.

### Logging

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_SCRIPT_LOG_FILE` | `false` | Save script logs to file |
| `ENABLE_FFMPEG_LOG_FILE` | `false` | Save FFmpeg output to file |
| `FFMPEG_LOG_LEVEL` | `info` | FFmpeg verbosity (error, info, verbose, debug) |
| `ENABLE_PROGRESS_UPDATES` | `false` | Show per-file progress percentage |

**Tip:** When troubleshooting stream drops or unexpected exits, temporarily enable `ENABLE_FFMPEG_LOG_FILE=true` with `FFMPEG_LOG_LEVEL=warning`. This logs only actual errors without creating huge log files.

### Advanced Settings

| Variable | Default | Description |
|----------|---------|-------------|
| `TWITCH_INGEST_URL` | `rtmp://live.twitch.tv/app` | Twitch ingest server (choose nearest) |
| `LOG_DIR` | `/data` | Directory for logs and playlists |

## Hardware Acceleration Setup

### Intel GPUs

1. **Verify VA-API device exists**
   ```bash
   ls -l /dev/dri/
   ```
   Look for `renderD128` and `card0`.

2. **Check group permissions**
   ```bash
   ls -l /dev/dri/renderD128
   # Should show: crw-rw---- 1 root render
   stat -c "%g" /dev/dri/renderD128
   # Note the group ID (usually 105 or 109)
   ```

3. **Update docker-compose.yaml**
   ```yaml
   group_add:
     - "105"  # Replace with your render group ID
     - "44"   # Replace with your video group ID
   ```

4. **Enable in configuration**
   ```bash
   ENABLE_HW_ACCEL=true
   VAAPI_DEVICE=/dev/dri/renderD128
   ```

### Testing Hardware Acceleration

```bash
# Enter the running container
docker exec -it twitch-gpu-streamer bash

# Test VA-API
vainfo

# Should show your GPU capabilities
```

## Choosing a Twitch Ingest Server

For optimal streaming performance, select a server closest to your location:

1. Visit [Twitch Ingest Recommendation](https://help.twitch.tv/s/twitch-ingest-recommendation)
2. Find your nearest server
3. Update in `.env`:
   ```
   TWITCH_INGEST_URL=rtmp://closest-server.contribute.live-video.net/app/
   ```

**Popular Ingest Servers:**
- Europe (Helsinki): `rtmp://hel03.contribute.live-video.net/app/`
- US East (New York): `rtmp://jfk05.contribute.live-video.net/app/`
- US West (San Francisco): `rtmp://sfo05.contribute.live-video.net/app/`

## Known Issues (These fixes are already included in script!)

### VA-API + Concat Demuxer: Filter Reinitialization Error

**Error:**
```
Impossible to convert between the formats supported by the filter 'Parsed_null_0' and the filter 'auto_scale_0'
Error reinitializing filters!
Failed to inject frame into filter network: Function not implemented
```

This is a known FFmpeg issue affecting VAAPI with the concat demuxer (multiple files in a playlist). It occurs when FFmpeg's automatic scaler (`auto_scale_0`) is inserted between filter stages and cannot handle the VAAPI surface context switching between files. The issue persists across FFmpeg versions including 6.x, 7.x, and 8.x.

**Fix:** Add `-noautoscale` immediately before the output destination in the FFmpeg command. In `start_ffmpeg_stream()` in `twitch_gpu_streamer.sh`, add it to the output section:

```bash
cmd+=(
     -max_muxing_queue_size 4096
     -rw_timeout 15000000
     -noautoscale                        # Required for VAAPI + concat stability
     -flvflags no_duration_filesize
     -rtmp_live live
     -f flv "$TWITCH_URL/$STREAM_KEY"
)
```

**Note on placement:** `-noautoscale` is an output option in FFmpeg 8.x and must appear before the output file, not before the input. Placing it before `-i` will produce an `Invalid argument` error.

**Additional stability tips for VA-API:**
- Set `USE_VIDEO_FILTER=false` if your source files already match your output resolution — this skips `scale_vaapi` entirely and reduces filter graph complexity
- Use `extra_hw_frames 48` (or higher) to give the VAAPI surface pool enough headroom during file transitions
- Add `-probesize 50M -analyzeduration 50M` to VAAPI options for more thorough format detection on each file

## Troubleshooting

### Stream Won't Start

**Error: "TWITCH_STREAM_KEY is not set"**
- Ensure your `.env` file exists and contains a valid stream key
- Check docker-compose.yaml loads the .env file correctly

**Error: "Found no video files"**
- Verify videos exist in the mounted directory: `ls -la ./videos/`
- Check `VIDEO_FILE_TYPES` matches your file extensions
- Ensure files are readable: `chmod 644 ./videos/*`

### Hardware Acceleration Issues

**Error: "VA-API device not found"**
- Check device exists: `ls -l /dev/dri/renderD128`
- Verify group_add IDs match your system
- Try software encoding: `ENABLE_HW_ACCEL=false`

**Error: "Failed to initialize VA-API"**
```bash
# Check GPU drivers
vainfo

# Install/update drivers
# Intel: sudo apt install intel-media-va-driver-non-free
# AMD: sudo apt install mesa-va-drivers
```

### Stream Quality Issues

**Low quality/pixelation**
- Increase `VIDEO_BITRATE` (try 4000k-6000k for 720p, 6000k-9000k for 1080p)
- Ensure sufficient upload bandwidth
- Check CPU/GPU usage isn't maxed out

**Audio/Video out of sync**
- Disable music temporarily to isolate issue
- Try software encoding: `ENABLE_HW_ACCEL=false`
- Reduce `STREAM_FRAMERATE` to 24 or 30

### Performance Optimization

**High CPU usage**
- Enable hardware acceleration: `ENABLE_HW_ACCEL=true`
- Lower resolution/framerate
- Use `-preset ultrafast` for software encoding

**Container stops unexpectedly**
```bash
# Check logs
docker-compose logs --tail=100

# Check system resources
docker stats

# Increase Docker memory limit if needed
```

## Architecture

```
┌───────────────────────────────────────────────────┐
│                  Docker Container                 │
├───────────────────────────────────────────────────┤
│                                                   │
│  ┌──────────────┐         ┌─────────────────────┐ │
│  │  Video Dir   │────────▶│  Playlist Generator │ │
│  │  /videos     │         └──────────┬──────────┘ │
│  └──────────────┘                    │            │
│                                      ▼            │
│  ┌──────────────┐         ┌─────────────────────┐ │
│  │  Music Dir   │────────▶│  video_list.txt     │ │
│  │  /music      │         │  music_list.txt     │ │
│  └──────────────┘         └──────────┬──────────┘ │
│                                      │            │
│                                      ▼            │
│                          ┌─────────────────────┐  │
│  ┌──────────────┐        │   FFmpeg Pipeline   │  │
│  │  VA-API GPU  │◀───────│                     │  │
│  │  /dev/dri    │        │  • Decode (VAAPI)   │  │
│  └──────────────┘        │  • Scale/Filter     │  │
│                          │  • Encode (h264)    │  │
│                          │  • Mux Audio        │  │
│                          └──────────┬──────────┘  │
│                                     │             │
│                                     ▼             │
│                          ┌─────────────────────┐  │
│                          │   RTMP Output       │  │
│                          │   Twitch Ingest     │──┼──▶ Twitch
│                          └─────────────────────┘  │
│                                                   │
│  ┌──────────────────────────────────────────────┐ │
│  │  Progress Monitor & Logging                  │ │
│  └──────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────┘
```

