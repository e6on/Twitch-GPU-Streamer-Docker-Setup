# --- Build Stage ---
# Extracts ffmpeg and installs the latest streamlink into a virtualenv.
# Nothing from this stage bleeds into the final image except what is
# explicitly copied.
FROM debian:trixie-slim AS builder

RUN apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install -y --no-install-recommends xz-utils python3 python3-venv

# Copy and extract the ffmpeg archive
COPY ffmpeg-n8.0.1-64-g15504610b0-linux64-gpl-8.0.tar.xz /tmp/
RUN tar -xf /tmp/ffmpeg-n8.0.1-64-g15504610b0-linux64-gpl-8.0.tar.xz -C /usr/local --strip-components=1

# Install latest streamlink into a virtualenv.
# Using a venv avoids Debian's non-standard pip --prefix layout and keeps
# pip out of the final image entirely.
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir streamlink

# --- Final Stage ---
FROM debian:trixie-slim

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Tallinn

# Enable non-free repos and install only runtime dependencies.
RUN sed -i 's/ main/ main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    bash \
    progress \
    vainfo \
    # Python runtime for streamlink (no pip — installed via venv in builder stage)
    python3 \
    # Runtime libs for VA-API hardware acceleration
    libva2 \
    libva-drm2 \
    libdrm2 \
    # Intel's non-free VA-API driver, often required for hardware encoding/decoding.
    intel-media-va-driver-non-free \
    # Timezone data
    tzdata \
    ca-certificates && \
    # Set timezone
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/*

# Copy the extracted ffmpeg binaries from the build stage.
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Copy the streamlink virtualenv from the build stage.
# The venv's bin/python3 is a symlink to /usr/bin/python3 which exists in
# the final image, so the venv is fully self-contained here.
COPY --from=builder /opt/venv /opt/venv
RUN ln -s /opt/venv/bin/streamlink /usr/local/bin/streamlink

# Copy scripts into the container
COPY twitch_gpu_streamer.sh /usr/local/bin/twitch_gpu_streamer.sh
RUN chmod +x /usr/local/bin/twitch_gpu_streamer.sh

LABEL org.opencontainers.image.title="Twitch GPU Streamer"
LABEL org.opencontainers.image.description="Docker container for streaming video to Twitch with VA-API GPU acceleration"
LABEL org.opencontainers.image.version="1.0"
LABEL org.opencontainers.image.authors="e6on"
LABEL org.opencontainers.image.url="https://github.com/e6on/Twitch-GPU-Streamer-Docker-Setup"
LABEL org.opencontainers.image.source="https://github.com/e6on/Twitch-GPU-Streamer-Docker-Setup"
LABEL org.opencontainers.image.licenses="MIT"

ENTRYPOINT ["/bin/bash", "/usr/local/bin/twitch_gpu_streamer.sh"]
