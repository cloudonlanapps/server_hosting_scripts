#!/bin/bash
set -e

if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: PROJECT_NAME environment variable is not set"
    exit 1
fi

# PACKAGE_NAME is the Python distribution this image actually installed, which
# is not always the deployment's name. PROJECT_NAME names the stack and its
# database; the package is whatever the server repo ships. Defaults to
# PROJECT_NAME, so existing deployments are unaffected.
PACKAGE_NAME="${PACKAGE_NAME:-$PROJECT_NAME}"

# Secrets arrive as tmpfs files under /run/secrets rather than as environment
# entries, so they stay out of `docker inspect` and /proc/<pid>/environ. The
# application reads its own settings straight from that directory; the two
# values below are needed by this script, so read them here.
#
# The environment is still honoured when a secret file is absent, so a
# deployment can move one value at a time instead of all at once.
read_secret() {
    local name="$1" file="/run/secrets/$1"
    if [ -r "$file" ]; then
        cat "$file"
    else
        eval "printf '%s' \"\${${name^^}:-}\""
    fi
}

POSTGRES_PASSWORD="$(read_secret postgres_password)"
BOOTSTRAP_PASSWORD="$(read_secret bootstrap_password)"

if [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: no postgres password: /run/secrets/postgres_password is absent and POSTGRES_PASSWORD is unset"
    exit 1
fi
if [ -z "$BOOTSTRAP_PASSWORD" ]; then
    echo "ERROR: no bootstrap password: /run/secrets/bootstrap_password is absent and BOOTSTRAP_PASSWORD is unset"
    exit 1
fi

echo "==> Waiting for PostgreSQL to be ready..."

# Wait for PostgreSQL to accept connections
until pg_isready -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" > /dev/null 2>&1; do
    echo "    Waiting for database..."
    sleep 2
done

# Additional wait for database to be fully ready
until PGPASSWORD="$POSTGRES_PASSWORD" psql -h db -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "SELECT 1" > /dev/null 2>&1; do
    echo "    Database accepting connections, waiting for readiness..."
    sleep 1
done

echo "    PostgreSQL is ready."

# --frozen --no-dev matches how the image was built (uv sync --frozen --no-dev).
# Without them `uv run` re-resolves the project on every start and installs the
# dev group — ruff, basedpyright, nodejs-wheel-binaries, ~80MB fetched before
# the server can answer a request. On a cold start that is slow enough to fail
# the deploy's health wait on a stack that is otherwise fine.
echo "==> Running database migrations..."
uv run --frozen --no-dev alembic upgrade head

# The password is still passed as an argument, so it is visible in this
# container's own /proc/<pid>/cmdline for the life of the command. That is a
# narrower exposure than the environment (which persisted for the life of the
# container and was readable via `docker inspect` from the host), but it is not
# nothing; closing it needs the bootstrap command to accept the value another
# way, which is an application change.
echo "==> Bootstrapping sudo user..."
uv run --frozen --no-dev ${PACKAGE_NAME}_bootstrap "$BOOTSTRAP_PASSWORD"

echo "==> Starting server..."
exec uv run --frozen --no-dev uvicorn ${PACKAGE_NAME}_server.main:app --host 0.0.0.0 --port 8000
