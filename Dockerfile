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

# Clone source from GitHub using HTTPS.
#
# For private repos the token arrives as a BuildKit secret mounted at
# /run/secrets/gh_token, not as a build arg. A build arg is substituted into
# the RUN instruction itself, so the token ends up in BuildKit's output and in
# `docker history` for the resulting image — readable by anyone who can pull
# it. The secret is a tmpfs file that exists only for this RUN and enters no
# layer.
#
# REPO_BRANCH accepts a branch, a tag, OR a full/short commit SHA. Left empty
# it defaults to main.
#
# `git clone --branch` resolves branches and tags but rejects a raw SHA
# ("fatal: Remote branch <sha> not found in upstream origin"), which is why
# deploying a specific commit was previously impossible. We keep that fast
# single-branch path for the common case and fall back to a full clone plus a
# detached checkout when the ref is a commit.
ARG REPO_BRANCH=
ARG GIT_URL
RUN --mount=type=secret,id=gh_token \
    if [ -z "$GIT_URL" ]; then \
        echo "ERROR: GIT_URL build arg is required"; \
        exit 1; \
    fi; \
    REPO_REF="${REPO_BRANCH:-main}"; \
    CLONE_URL="$GIT_URL"; \
    if [ -s /run/secrets/gh_token ]; then \
        GH_TOKEN="$(cat /run/secrets/gh_token)"; \
        CLONE_URL="https://${GH_TOKEN}@${GIT_URL#https://}"; \
        unset GH_TOKEN; \
    fi; \
    echo "==> Fetching ${REPO_REF}"; \
    if git clone --branch "$REPO_REF" --single-branch "$CLONE_URL" /app 2>/tmp/clone_err; then \
        echo "==> Checked out ${REPO_REF} (branch or tag)"; \
    else \
        echo "==> ${REPO_REF} is not a branch or tag; retrying as a commit"; \
        # cd out of /app first: it is the WORKDIR, so it is this shell's cwd, \
        # and removing it leaves git unable to resolve a working directory. \
        cd / && rm -rf /app; \
        if git clone "$CLONE_URL" /app 2>>/tmp/clone_err; then \
            git -C /app checkout --detach "$REPO_REF" 2>>/tmp/clone_err \
            || { echo ""; \
                 echo "ERROR: '${REPO_REF}' is not a branch, tag, or commit in this repository."; \
                 echo ""; \
                 cat /tmp/clone_err; \
                 exit 1; }; \
            echo "==> Checked out ${REPO_REF} (commit)"; \
        else \
            echo ""; \
            echo "ERROR: Failed to clone repository."; \
            if [ ! -s /run/secrets/gh_token ]; then \
                echo "The repo may be private. Re-run with --github-token <TOKEN>"; \
            fi; \
            echo ""; \
            cat /tmp/clone_err; \
            exit 1; \
        fi; \
    fi; \
    echo "==> Deployed commit: $(git -C /app rev-parse HEAD)" \
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
