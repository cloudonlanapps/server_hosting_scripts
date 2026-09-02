#!/bin/bash
set -e

if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: PROJECT_NAME environment variable is not set"
    exit 1
fi

# PACKAGE_NAME is the Python distribution this image actually installed, which
# is not always the deployment's name. PROJECT_NAME names *this deployment* —
# its stack, database, data directory and secrets — while the package is a
# property of the application repo, identical across every deployment of it.
# One varies per deployment, the other does not, so defaulting one to the other
# only held while a single product existed.
#
# Read it from the repo the image already cloned. The application declares it
# in pyproject.toml, so the conf does not have to repeat it. An explicit
# PACKAGE_NAME still wins, for a repo that does not follow the <name>_server
# convention.
if [ -z "${PACKAGE_NAME:-}" ]; then
    PACKAGE_NAME="$(sed -n 's/^name *= *"\(.*\)"/\1/p' /app/pyproject.toml 2>/dev/null \
                    | head -1 | tr '-' '_' | sed 's/_server$//')"
fi

# Getting this wrong used to be near-silent: the container started, connected,
# ran migrations successfully, then failed to find the bootstrap command and
# restarted forever — a database migrated by a server that never serves, caught
# only by the health check. Check up front and say so instead.
if [ -z "$PACKAGE_NAME" ]; then
    echo "ERROR: could not determine the Python package name."
    echo "       Expected a [project] name in /app/pyproject.toml, e.g."
    echo '         name = "myproduct-server"   ->   package "myproduct"'
    echo "       Set PACKAGE_NAME explicitly if this repo does not follow that convention."
    exit 1
fi
if ! uv run --frozen --no-dev python -c \
        "import shutil,sys; sys.exit(0 if shutil.which('${PACKAGE_NAME}_bootstrap') else 1)" \
        >/dev/null 2>&1; then
    echo "ERROR: no such command '${PACKAGE_NAME}_bootstrap' in this image."
    echo "       The server repo must ship a '<package>_bootstrap' entry point, or"
    echo "       PACKAGE_NAME must be set to whatever it does ship."
    exit 1
fi
echo "==> Python package: $PACKAGE_NAME"

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
