# syntax=docker/dockerfile:1
FROM python:3.12-slim

# Install dependencies:
# - curl: for healthcheck
# - git: for cloning from GitHub
# - postgresql-client: for pg_isready in entrypoint
# - ffmpeg, poppler-utils: image/video/PDF conversion pipeline used by uploads
# - wget, ca-certificates: fetching the ImageMagick v7 portable binary below
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        git \
        postgresql-client \
        ffmpeg \
        poppler-utils \
        ca-certificates \
        wget \
    && rm -rf /var/lib/apt/lists/* \
    # ImageMagick v7 — Debian ships only v6 (no `magick` binary that the
    # server's media_convert.sh requires). Pull a pinned release AppImage
    # from GitHub (bytes are immutable per tag) and verify its SHA-256
    # before installing. Bump IM_VERSION + IM_SHA256 together to upgrade.
    && IM_VERSION=7.1.2-23 \
    && IM_SHA256=394276441870822786a8bb0ef8ec56db744567d2662ba5c1e1404e2ad969a28b \
    && wget -O /tmp/magick.AppImage \
        "https://github.com/ImageMagick/ImageMagick/releases/download/${IM_VERSION}/ImageMagick-${IM_VERSION}-gcc-x86_64.AppImage" \
    && echo "${IM_SHA256}  /tmp/magick.AppImage" | sha256sum -c - \
    && chmod +x /tmp/magick.AppImage \
    # Docker has no FUSE, so extract the AppImage instead of executing it.
    && (cd /opt && /tmp/magick.AppImage --appimage-extract >/dev/null) \
    && mv /opt/squashfs-root /opt/imagemagick \
    && ln -s /opt/imagemagick/AppRun /usr/local/bin/magick \
    && rm /tmp/magick.AppImage \
    && magick -version | head -1

# Build-time smoke test of the upload-conversion pipeline. The tools we
# just installed (magick / ffmpeg) are themselves used to synthesize tiny
# sample inputs, then we run them through the same conversions the
# server's media_convert.sh performs on real uploads. Any failure breaks
# the build, so a broken image can never be deployed.
#
# Verified paths:
#   image  → magick resize + WebP encode
#   video  → ffmpeg H.264 encode + libwebp_anim encoder present
RUN set -e \
    && mkdir -p /tmp/media_check \
    && cd /tmp/media_check \
    # Image path.
    && magick -size 100x100 xc:red sample.png \
    && magick sample.png -resize 100x100 -quality 90 sample.webp \
    && test -s sample.webp \
    # Video path.
    && ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i color=c=blue:s=320x240:d=2 \
        -c:v libx264 sample.mp4 \
    && test -s sample.mp4 \
    && ffmpeg -hide_banner -encoders 2>/dev/null \
        | grep -q "libwebp_anim" \
    # pdftoppm is the only PDF tool we use; sanity-check it loads.
    && pdftoppm -v >/dev/null 2>&1 \
    && rm -rf /tmp/media_check \
    && echo "media-conversion smoke test passed"

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Clone source from GitHub using HTTPS
# For private repos, pass GITHUB_TOKEN build arg
ARG GITHUB_TOKEN=
ARG REPO_BRANCH=
ARG GIT_URL
RUN if [ -z "$GIT_URL" ]; then \
        echo "ERROR: GIT_URL build arg is required"; \
        exit 1; \
    fi; \
    BRANCH_FLAG=""; \
    if [ -n "$REPO_BRANCH" ]; then \
        BRANCH_FLAG="--branch ${REPO_BRANCH} --single-branch"; \
    fi; \
    if [ -n "$GITHUB_TOKEN" ]; then \
        GIT_URL_WITH_TOKEN=$(echo "$GIT_URL" | sed "s|https://|https://${GITHUB_TOKEN}@|"); \
        git clone $BRANCH_FLAG "$GIT_URL_WITH_TOKEN" /app; \
    else \
        git clone $BRANCH_FLAG "$GIT_URL" /app 2>/tmp/clone_err \
        || { echo ""; \
             echo "ERROR: Failed to clone repository without a token."; \
             echo "The repo may be private. Re-run with --github-token <TOKEN>"; \
             echo ""; \
             cat /tmp/clone_err; \
             exit 1; }; \
    fi \
    # Remove git static folder - will be mounted from host
    && rm -rf /app/static

# Install dependencies (without dev dependencies)
RUN uv sync --frozen --no-dev

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose port
EXPOSE 8000

# Use entrypoint script for migrations and bootstrap
ENTRYPOINT ["/entrypoint.sh"]
