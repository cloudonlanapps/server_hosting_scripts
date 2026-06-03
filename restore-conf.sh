#!/bin/bash
set -euo pipefail

# Usage: ./restore-conf.sh <conf-file> <target-env> <backup-dir>
#
# Restore a backup produced by backup-conf.sh INTO a (possibly different)
# deployed environment of the SAME project — e.g. restore a prod backup into
# beta, or a beta backup into prod. Overwrites the target's database and its
# uploaded-media / static directories, then restarts the target server (which
# re-runs `alembic upgrade head` on boot — so restoring an older-schema backup
# into a newer-code instance performs the migration as a side effect).
#
#   <backup-dir>  a timestamp dir from backup-conf.sh, containing db.dump,
#                 uploads.tgz, (optional) static.tgz and MANIFEST.txt.
#
# Knobs (environment):
#   FORCE=1       skip the interactive "type the env to confirm" prompt
#   NO_RESTART=1  restore data but leave the server stopped (inspect first)
#
# DESTRUCTIVE. The target env's current DB + files are replaced. There is no
# undo — take a fresh backup of the target first if you might need it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -ne 3 ]; then
    echo "Usage: $0 <conf-file> <target-env> <backup-dir>"
    exit 1
fi

CONF_FILE="$1"
ENV="$2"
BK="${3%/}"

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Conf file not found: $CONF_FILE"
    exit 1
fi
if [ ! -d "$BK" ]; then
    echo "ERROR: Backup dir not found: $BK"
    exit 1
fi
for f in db.dump uploads.tgz MANIFEST.txt; do
    if [ ! -f "$BK/$f" ]; then
        echo "ERROR: Backup dir is missing $f: $BK"
        exit 1
    fi
done

# shellcheck disable=SC1090
source "$CONF_FILE"

if [ -z "${PROJECT:-}" ]; then
    echo "ERROR: $CONF_FILE must define PROJECT"
    exit 1
fi
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then
    echo "ERROR: $CONF_FILE must define ENVS=(...)"
    exit 1
fi
ENV_OK=false
for e in "${ENVS[@]}"; do
    [ "$e" = "$ENV" ] && ENV_OK=true && break
done
if [ "$ENV_OK" = false ]; then
    echo "ERROR: Unknown target env '$ENV'. Allowed: ${ENVS[*]}"
    exit 1
fi

PASS_PREFIX="${PASS_PREFIX:-$PROJECT}"

# --- Read backup metadata ---
manifest_get() { awk -F': *' -v k="$1" '$1==k {print $2; exit}' "$BK/MANIFEST.txt"; }
SRC_PROJECT="$(manifest_get project)"
SRC_ENV="$(manifest_get env)"
SRC_SCHEMA="$(manifest_get alembic_version)"

if [ -n "$SRC_PROJECT" ] && [ "$SRC_PROJECT" != "$PROJECT" ]; then
    echo "ERROR: backup is from project '$SRC_PROJECT' but conf PROJECT is '$PROJECT'."
    echo "  Cross-project restore is not supported (DB name = project name)."
    exit 1
fi

# --- Resolve target container / data-dir like deploy.sh ---
GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"
GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"
    exit 1
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

# --- Secrets ---
if ! command -v pass &>/dev/null; then echo "ERROR: 'pass' not installed."; exit 1; fi
PW_KEY="${PASS_PREFIX}/${ENV}/postgres-password"
if ! pass show "$PW_KEY" &>/dev/null; then
    echo "ERROR: Missing secret in pass store: $PW_KEY"
    exit 1
fi
POSTGRES_PASSWORD="$(pass show "$PW_KEY")"

# --- Preconditions ---
if ! command -v docker &>/dev/null; then echo "ERROR: docker not found — run on the host."; exit 1; fi
if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: target postgres container '$DB_CONTAINER' is not running. Deploy it first (just deploy $ENV)."
    exit 1
fi

# --- SECRET_KEY mismatch warning (encrypted media won't decrypt across keys) ---
SK_NOTE=""
SRC_SK_KEY="${PASS_PREFIX}/${SRC_ENV}/secret-key"
TGT_SK_KEY="${PASS_PREFIX}/${ENV}/secret-key"
if [ -n "$SRC_ENV" ] && pass show "$SRC_SK_KEY" &>/dev/null && pass show "$TGT_SK_KEY" &>/dev/null; then
    if [ "$(pass show "$SRC_SK_KEY")" != "$(pass show "$TGT_SK_KEY")" ]; then
        SK_NOTE="WARNING: target secret-key ($ENV) differs from source ($SRC_ENV). Encrypted media (identity documents) in this backup will NOT be decryptable on $ENV unless $ENV is redeployed with the source's secret-key."
    fi
else
    SK_NOTE="NOTE: could not compare secret-keys (missing pass entry) — if they differ, encrypted media will not decrypt on $ENV."
fi

# --- Confirm (destructive) ---
echo "============================================================"
echo " RESTORE  ${SRC_ENV:-?} backup  ->  ${ENV}  (project ${PROJECT})"
echo "   backup:        $BK"
echo "   backup schema: ${SRC_SCHEMA:-unknown}"
echo "   target DB:     $DB_CONTAINER / $POSTGRES_DB   (WILL BE DROPPED & REPLACED)"
echo "   target files:  $UPLOAD_DIR , $STATIC_DIR   (WILL BE REPLACED)"
echo "   after restore: $([ -n "${NO_RESTART:-}" ] && echo 'server left STOPPED' || echo "restart $SERVER_CONTAINER -> runs alembic upgrade head")"
[ -n "$SK_NOTE" ] && echo "   $SK_NOTE"
[ "$ENV" = "prod" ] && echo "   *** TARGET IS PROD — this overwrites production data. ***"
echo "============================================================"
if [ -z "${FORCE:-}" ]; then
    read -r -p "Type the target env name '$ENV' to proceed: " ans
    [ "$ans" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# --- Stop the target server so it holds no connections / doesn't migrate mid-restore ---
echo "==> Stopping $SERVER_CONTAINER ..."
docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true

# --- 1. Recreate the target database and load the dump ---
echo "==> Recreating database $POSTGRES_DB ..."
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\" WITH (FORCE);" \
    -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\";"

echo "==> Restoring database dump ..."
if ! docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
        pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner <"$BK/db.dump"; then
    echo "WARN: pg_restore exited non-zero (often harmless owner/role notices with --no-owner); review output above."
fi

# --- 2. Replace the target's uploaded-media + static files ---
restore_dir() {  # <archive> <target-dir>
    local archive="$1" target="$2"
    case "$target" in
        "$HOME/.local/share/"*) ;;  # guard: only ever wipe under the data base
        *) echo "ERROR: refusing to wipe unexpected path: $target"; exit 1;;
    esac
    mkdir -p "$target"
    find "$target" -mindepth 1 -delete
    tar -xzf "$archive" -C "$target"
}
echo "==> Restoring uploaded media -> $UPLOAD_DIR ..."
restore_dir "$BK/uploads.tgz" "$UPLOAD_DIR"
if [ -f "$BK/static.tgz" ]; then
    echo "==> Restoring static assets -> $STATIC_DIR ..."
    restore_dir "$BK/static.tgz" "$STATIC_DIR"
fi

# --- 3. Bring the server back (re-runs migrations on boot) ---
if [ -n "${NO_RESTART:-}" ]; then
    echo "==> NO_RESTART set: leaving $SERVER_CONTAINER stopped."
    echo "    Start it with: docker start $SERVER_CONTAINER   (will run alembic upgrade head)"
else
    echo "==> Starting $SERVER_CONTAINER (runs alembic upgrade head) ..."
    docker start "$SERVER_CONTAINER" >/dev/null
    sleep 2
    docker compose -p "$COMPOSE_PROJECT_NAME" logs --tail=30 server 2>/dev/null \
        || docker logs --tail=30 "$SERVER_CONTAINER" 2>&1 || true
fi

echo "==> Restore complete: ${SRC_ENV:-?} (schema ${SRC_SCHEMA:-unknown}) -> ${ENV}."
echo "    Watch migrations:  docker logs -f $SERVER_CONTAINER"
