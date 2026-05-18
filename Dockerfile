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
    # server's media_convert.sh requires). Fetch the official portable
    # AppImage, extract it (Docker has no FUSE), and link AppRun as
    # /usr/local/bin/magick.
    && wget -O /tmp/magick https://imagemagick.org/archive/binaries/magick \
    && chmod +x /tmp/magick \
    && (cd /opt && /tmp/magick --appimage-extract >/dev/null) \
    && mv /opt/squashfs-root /opt/imagemagick \
    && ln -s /opt/imagemagick/AppRun /usr/local/bin/magick \
    && rm /tmp/magick \
    && magick -version | head -1

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
