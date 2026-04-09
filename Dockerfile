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
ARG GITHUB_TOKEN=
ARG REPO_BRANCH=main
RUN if [ -n "$GITHUB_TOKEN" ]; then \
        git clone --branch ${REPO_BRANCH} --single-branch \
            https://${GITHUB_TOKEN}@github.com/cloudonlanapps/club_server.git /app; \
    else \
        git clone --branch ${REPO_BRANCH} --single-branch \
            https://github.com/cloudonlanapps/club_server.git /app 2>/tmp/clone_err \
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
