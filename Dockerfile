# syntax=docker/dockerfile:1
FROM python:3.12-slim

# Install dependencies:
# - curl: for healthcheck
# - git: for cloning from GitHub
# - postgresql-client: for pg_isready in entrypoint
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBCONF_NONINTERACTIVE_SEEN=true
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Clone source from GitHub using HTTPS
# For private repos, pass GITHUB_TOKEN build arg
#
# REPO_BRANCH accepts a branch, a tag, OR a full/short commit SHA. Left empty
# it defaults to main.
#
# `git clone --branch` resolves branches and tags but rejects a raw SHA
# ("fatal: Remote branch <sha> not found in upstream origin"), which is why
# deploying a specific commit was previously impossible. We keep that fast
# single-branch path for the common case and fall back to a full clone plus a
# detached checkout when the ref is a commit.
ARG GITHUB_TOKEN=
ARG REPO_BRANCH=
ARG GIT_URL
RUN if [ -z "$GIT_URL" ]; then \
        echo "ERROR: GIT_URL build arg is required"; \
        exit 1; \
    fi; \
    REPO_REF="${REPO_BRANCH:-main}"; \
    CLONE_URL="$GIT_URL"; \
    if [ -n "$GITHUB_TOKEN" ]; then \
        CLONE_URL=$(echo "$GIT_URL" | sed "s|https://|https://${GITHUB_TOKEN}@|"); \
    fi; \
    echo "==> Fetching ${REPO_REF}"; \
    if git clone --branch "$REPO_REF" --single-branch "$CLONE_URL" /app 2>/tmp/clone_err; then \
        echo "==> Checked out ${REPO_REF} (branch or tag)"; \
    else \
        echo "==> ${REPO_REF} is not a branch or tag; retrying as a commit"; \
        rm -rf /app; \
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
            if [ -z "$GITHUB_TOKEN" ]; then \
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
