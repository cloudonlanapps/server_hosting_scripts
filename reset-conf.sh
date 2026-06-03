#!/bin/bash
set -euo pipefail

# Usage: ./reset-conf.sh <conf-file> <env>
#
# Blank a deployed environment: stop its server, DROP and recreate an EMPTY
# database, and clear its uploaded-media / static directories. The server is
# left STOPPED so the empty state survives (starting it would re-run
# `alembic upgrade head` and recreate the schema).
#
# Single purpose: it only blanks. It does NOT back up and does NOT restore —
# chain those separately (see `just restore-clean`). No DB password needed:
# the dump/admin commands run via `docker exec` over the container's trusted
# local socket.
#
# Knobs:  FORCE=1   skip the interactive "type the env to confirm" prompt
#
# DESTRUCTIVE and irreversible. Take a backup first if the data matters
# (backup-conf.sh / `just backup <env>`).

if [ $# -ne 2 ]; then
    echo "Usage: $0 <conf-file> <env>"
    exit 1
fi

CONF_FILE="$1"
ENV="$2"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Conf file not found: $CONF_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

if [ -z "${PROJECT:-}" ]; then echo "ERROR: $CONF_FILE must define PROJECT"; exit 1; fi
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then
    echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 1
fi
ENV_OK=false
for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
if [ "$ENV_OK" = false ]; then
    echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"; exit 1
fi

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"
GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 1
fi

DATA_BASE="${HOME}/.local/share"
if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    if [ -n "$GIT_BRANCH" ]; then DATA_DIR="${DATA_BASE}/server_dev_${PROJECT}_${GIT_BRANCH}"
    else DATA_DIR="${DATA_BASE}/server_dev_${PROJECT}"; fi
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_DIR="${DATA_BASE}/server_${PROJECT}_${GIT_BRANCH}"
fi
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
SERVER_CONTAINER="${COMPOSE_PROJECT_NAME}-server"
UPLOAD_DIR="${DATA_DIR}/uploads"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"
POSTGRES_USER="$PROJECT"

# --- Preconditions ---
if ! command -v docker &>/dev/null; then echo "ERROR: docker not found — run on the host."; exit 1; fi
if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running. Deploy it first (just deploy $ENV)."
    exit 1
fi

# --- Confirm (destructive) ---
echo "============================================================"
echo " RESET (blank) ${ENV}  (project ${PROJECT})"
echo "   DB:    $DB_CONTAINER / $POSTGRES_DB    -> DROP & recreate EMPTY"
echo "   files: $UPLOAD_DIR , $STATIC_DIR       -> cleared"
echo "   server $SERVER_CONTAINER               -> left STOPPED"
[ "$ENV" = "prod" ] && echo "   *** TARGET IS PROD — this erases production data. ***"
echo "============================================================"
if [ -z "${FORCE:-}" ]; then
    read -r -p "Type the env name '$ENV' to proceed: " ans
    [ "$ans" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# --- Stop the server so nothing reconnects / re-migrates ---
echo "==> Stopping $SERVER_CONTAINER ..."
docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true

# --- Drop + recreate an empty database ---
echo "==> Dropping and recreating empty database $POSTGRES_DB ..."
docker exec "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" \
    -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"

# --- Clear the upload/static dirs (guarded) ---
clear_dir() {  # <dir>
    local d="$1"
    case "$d" in
        "$HOME/.local/share/"*) ;;  # only ever wipe under the data base
        *) echo "ERROR: refusing to wipe unexpected path: $d"; exit 1;;
    esac
    mkdir -p "$d"
    find "$d" -mindepth 1 -delete
}
echo "==> Clearing $UPLOAD_DIR ..."
clear_dir "$UPLOAD_DIR"
echo "==> Clearing $STATIC_DIR ..."
clear_dir "$STATIC_DIR"

echo "==> Reset complete: $ENV is blank (server left stopped)."
echo "    Restore a backup:  restore-conf.sh $CONF_FILE $ENV <backup-dir>"
echo "    Or just start fresh: docker start $SERVER_CONTAINER  (runs migrations on the empty DB)"
