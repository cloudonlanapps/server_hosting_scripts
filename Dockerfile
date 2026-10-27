# syntax=docker/dockerfile:1
#
# The deploy's image: this host's template (Dockerfile.base, built by
# refresh-base.sh) plus the server's code. Only what changes between deploys
# is here: the clone, its dependencies and the entrypoint.
#
# deploy.sh passes BASE_IMAGE, the template's tag for this Dockerfile.base, and
# builds the template first if this host does not have it.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

WORKDIR /app

# Everything from here is rebuilt on every deploy: deploy.sh passes a new
# DEPLOY_ID each time, and its first use below (the clone) misses the cache.
# This stands in for --no-cache, which would also empty the uv cache mount.
ARG DEPLOY_ID=

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
    echo "==> Deploy ${DEPLOY_ID}: fetching ${REPO_REF}"; \
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
    echo "==> Deployed commit: $(git -C /app rev-parse HEAD)"; \
    # The clone URL carries the token, and git writes it verbatim into
    # /app/.git/config, where it survives into the image and every container
    # started from it. Reset the remote to the plain URL.
    #
    # /app/.git itself is kept on purpose: the commit recorded there is the
    # only record of what a running container was built from, and it was the
    # sole way to establish what a two-month-old production deployment was
    # actually serving. Stripping the credential keeps the traceability.
    git -C /app remote set-url origin "$GIT_URL"; \
    if git -C /app config --get-regexp '^remote\..*\.url$' | grep -qE '://[^/@[:space:]]+@'; then \
        echo "ERROR: a credential survives in /app/.git/config"; \
        exit 1; \
    fi \
    # Remove git static folder - will be mounted from host
    && rm -rf /app/static

# Install dependencies (without dev dependencies).
#
# uv's download cache is a BuildKit cache mount, kept on the host across
# builds (one run with --no-cache gets an empty one), so a deploy downloads
# only the packages this host has not fetched before; uv.lock's hashes check
# every one. The venv gets copies, since the cache is not in the image.
#
# UV_OFFLINE set (any value) installs from that cache alone, never asking
# PyPI: for a day PyPI is unreachable from this host and the cache already
# holds every package uv.lock names.
ENV UV_LINK_MODE=copy
ARG UV_OFFLINE=
RUN --mount=type=cache,id=server_hosting_uv,target=/root/.cache/uv \
    if [ -n "$UV_OFFLINE" ]; then \
        echo "==> uv sync offline, from this host's cache"; \
        uv sync --frozen --no-dev --offline; \
    else \
        env -u UV_OFFLINE uv sync --frozen --no-dev; \
    fi

# The venv is complete once built, and the cache above is not in the image:
# entrypoint.sh's `uv run` must use the venv as it is, not sync it again,
# which would ask PyPI for the build backend on every start.
ENV UV_NO_SYNC=1

# The app checks outbound TLS against certifi, which still trusts emSign
# Root CA - G1 while the hosts and the system store above distrust every
# emSign root. Remove them from the app's bundle too; the script fails the
# build if one is left.
COPY distrust-emsign-certifi.py /tmp/distrust-emsign-certifi.py
RUN /app/.venv/bin/python -I /tmp/distrust-emsign-certifi.py \
    && rm /tmp/distrust-emsign-certifi.py

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose port
EXPOSE 8000

# Use entrypoint script for migrations and bootstrap
ENTRYPOINT ["/entrypoint.sh"]
