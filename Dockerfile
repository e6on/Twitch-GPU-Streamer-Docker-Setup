# --- Build Stage ---
# This stage is only used to extract the ffmpeg binary from its archive.
# Its contents will be discarded and will not be part of the final image.
FROM debian:bookworm-slim AS builder

# Install the extraction tool
RUN apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install -y --no-install-recommends xz-utils

# Copy and extract the ffmpeg archive
#COPY ffmpeg-master-latest-linux64-gpl.tar.xz /tmp/
#RUN tar -xf /tmp/ffmpeg-master-latest-linux64-gpl.tar.xz -C /usr/local --strip-components=1
COPY ffmpeg-6.1.2-linux-amd64.tar.xz /tmp/
RUN tar -xf /tmp/ffmpeg-6.1.2-linux-amd64.tar.xz -C /usr/local --strip-components=1

# --- Final Stage ---
# This is the final, optimized image that will be used.
FROM debian:bookworm-slim

# Set shell to bash and ensure commands exit on error.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# Set non-interactive frontend for package installation.
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Tallinn

# Enable non-free repos and install only runtime dependencies.
RUN sed -i 's/ main/ main contrib non-free non-free-firmware/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
    # Bash is used by the entrypoint script
    bash \
    progress \
    vainfo \
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
    # Clean up apt caches
    apt-get autoremove -y && \
    apt-get autoclean && \
    rm -rf /var/lib/apt/lists/*

# Copy the extracted ffmpeg binaries from the build stage.
COPY --from=builder /usr/local/bin/ffmpeg /usr/local/bin/ffmpeg
COPY --from=builder /usr/local/bin/ffprobe /usr/local/bin/ffprobe

# Copy scripts into the container
COPY twitch_gpu_streamer.sh /usr/local/bin/twitch_gpu_streamer.sh

# Set execute permissions for the scripts
RUN chmod +x /usr/local/bin/twitch_gpu_streamer.sh

# Add metadata labels
LABEL org.opencontainers.image.title="Twitch GPU Streamer"
LABEL org.opencontainers.image.description="Docker container for streaming video to Twitch with VA-API GPU acceleration"
LABEL org.opencontainers.image.version="1.0"
LABEL org.opencontainers.image.authors="e6on"
LABEL org.opencontainers.image.url="https://github.com/e6on/Twitch-GPU-Streamer-Docker-Setup"
LABEL org.opencontainers.image.source="https://github.com/e6on/Twitch-GPU-Streamer-Docker-Setup"
LABEL org.opencontainers.image.licenses="MIT"

# Set the entrypoint to run the streaming script explicitly with bash to avoid exec format errors
ENTRYPOINT ["/bin/bash", "/usr/local/bin/twitch_gpu_streamer.sh"]