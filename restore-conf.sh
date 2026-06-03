#!/bin/bash
set -euo pipefail

# Usage: ./restore-conf.sh <conf-file> <target-env> <backup-dir>
#
# Load a backup (produced by backup-conf.sh) INTO a deployed environment of
# the SAME project — e.g. a prod backup into beta, or beta into prod.
#
# Single purpose: it ONLY loads. It REFUSES to run unless the target is
# already blank (empty database AND empty upload/static dirs). To replace a
# populated env, blank it first with reset-conf.sh (`just reset <env>`), or
# use the `just restore-clean` orchestrator which chains backup -> reset ->
# restore. This script never drops a database or deletes files.
#
#   <backup-dir>  a timestamp dir from backup-conf.sh, containing db.dump,
#                 uploads.tgz, (optional) static.tgz and MANIFEST.txt.
#
# FAIL-SAFE schema check: the backup's alembic revision must EXACTLY equal the
# target env's code migration head. If they differ at all, restore refuses —
# it never lets the server "upgrade" or "downgrade" restored data. (To migrate,
# restore into a matching-code env and then deploy newer code deliberately.)
#
# Knobs:
#   FORCE=1       skip the interactive confirmation prompt
#   NO_RESTART=1  load data but leave the server stopped (inspect first)
#   CHECK_ONLY=1  run all validations (incl. the schema check) and exit without
#                 loading — used by `just restore-clean` to fail fast BEFORE the
#                 target is blanked. Skips the empty-target check.
#
# No DB password needed: pg_restore runs via `docker exec` over the
# container's trusted local socket.

if [ $# -ne 3 ]; then
    echo "Usage: $0 <conf-file> <target-env> <backup-dir>"
    exit 1
fi

CONF_FILE="$1"
ENV="$2"
BK="${3%/}"

if [ ! -f "$CONF_FILE" ]; then echo "ERROR: Conf file not found: $CONF_FILE"; exit 1; fi
if [ ! -d "$BK" ]; then echo "ERROR: Backup dir not found: $BK"; exit 1; fi
for f in db.dump uploads.tgz MANIFEST.txt; do
    if [ ! -f "$BK/$f" ]; then echo "ERROR: Backup dir is missing $f: $BK"; exit 1; fi
done

# shellcheck disable=SC1090
source "$CONF_FILE"

if [ -z "${PROJECT:-}" ]; then echo "ERROR: $CONF_FILE must define PROJECT"; exit 1; fi
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 1; fi
ENV_OK=false
for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
if [ "$ENV_OK" = false ]; then echo "ERROR: Unknown target env '$ENV'. Allowed: ${ENVS[*]}"; exit 1; fi

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
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 1; fi
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
    echo "ERROR: target postgres container '$DB_CONTAINER' is not running. Deploy it first (just deploy $ENV)."
    exit 1
fi

# --- FAIL-SAFE: backup schema must EXACTLY equal the target code's head ---
# Uses only the backup MANIFEST + the target's code image (no DB state), so it
# is valid to run before the target is blanked.
echo "==> Verifying schema compatibility ..."
B_REV="$SRC_SCHEMA"
if [ -z "$B_REV" ] || [ "$B_REV" = "(unknown)" ]; then
    echo "ERROR: backup MANIFEST has no alembic_version — cannot verify compatibility. Refusing."
    exit 1
fi
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$SERVER_CONTAINER" 2>/dev/null || true)"
if [ -z "$IMAGE" ]; then
    echo "ERROR: server container '$SERVER_CONTAINER' not found; deploy $ENV first so its code head is known."
    exit 1
fi
# `alembic heads` reads only the migration scripts (no DB). Dummy settings env
# satisfies any module-level config import without connecting to anything.
CODE_HEADS="$(docker run --rm --entrypoint sh \
    -e DATABASE_URL='postgresql+asyncpg://u:u@localhost:5432/u' \
    -e SECRET_KEY=x -e UPLOAD_DIR=/tmp -e STATIC_DIR=/tmp -e PROJECT_NAME="$PROJECT" \
    "$IMAGE" -c 'cd /app && uv run alembic heads 2>/dev/null' \
    | awk '{print $1}' | grep -E '^[0-9A-Za-z_]+$' || true)"
if [ -z "$CODE_HEADS" ]; then
    echo "ERROR: could not determine $ENV code migration head from image $IMAGE. Refusing."
    exit 1
fi
N_HEADS="$(printf '%s\n' "$CODE_HEADS" | grep -c .)"
if [ "$N_HEADS" -ne 1 ] || [ "$CODE_HEADS" != "$B_REV" ]; then
    echo "ERROR: schema mismatch — restore refused (fail-safe)."
    echo "    backup schema:   $B_REV   (from ${SRC_ENV:-?})"
    echo "    $ENV code head:  $(printf '%s ' $CODE_HEADS)"
    echo "  Restore only proceeds when the backup schema EQUALS the target code head."
    echo "  Deploy $ENV at the code whose head is '$B_REV', or restore a backup taken at the code head above."
    exit 1
fi
echo "    OK: backup schema $B_REV matches $ENV code head."

if [ -n "${CHECK_ONLY:-}" ]; then
    echo "==> CHECK_ONLY: compatibility verified; not loading."
    exit 0
fi

# --- Refuse a non-empty target (this script does not blank anything) ---
if ! docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB'" | grep -q 1; then
    echo "ERROR: database '$POSTGRES_DB' does not exist on $ENV. Blank it first: just reset $ENV"
    exit 1
fi
TABLE_COUNT="$(docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" \
    | tr -d '[:space:]')"
if [ "${TABLE_COUNT:-0}" != "0" ]; then
    echo "ERROR: target DB '$POSTGRES_DB' is NOT empty (${TABLE_COUNT} tables)."
    echo "  This script only loads into a blank env. Blank it first: just reset $ENV"
    echo "  (or use: just restore-clean $ENV $BK  — which backs up, resets, then restores)"
    exit 1
fi
dir_nonempty() { [ -d "$1" ] && [ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]; }
for d in "$UPLOAD_DIR" "$STATIC_DIR"; do
    if dir_nonempty "$d"; then
        echo "ERROR: target dir is NOT empty: $d"
        echo "  Blank it first: just reset $ENV"
        exit 1
    fi
done

# --- SECRET_KEY mismatch warning (encrypted media won't decrypt across keys) ---
SK_NOTE=""
if command -v pass &>/dev/null && [ -n "$SRC_ENV" ]; then
    SRC_SK_KEY="${PASS_PREFIX}/${SRC_ENV}/secret-key"
    TGT_SK_KEY="${PASS_PREFIX}/${ENV}/secret-key"
    if pass show "$SRC_SK_KEY" &>/dev/null && pass show "$TGT_SK_KEY" &>/dev/null; then
        if [ "$(pass show "$SRC_SK_KEY")" != "$(pass show "$TGT_SK_KEY")" ]; then
            SK_NOTE="WARNING: target secret-key ($ENV) differs from source ($SRC_ENV). Encrypted media (identity documents) in this backup will NOT be decryptable on $ENV unless $ENV is redeployed with the source's secret-key."
        fi
    else
        SK_NOTE="NOTE: could not compare secret-keys (missing pass entry) — if they differ, encrypted media will not decrypt on $ENV."
    fi
fi

# --- Confirm ---
echo "============================================================"
echo " RESTORE  ${SRC_ENV:-?} backup  ->  ${ENV}  (project ${PROJECT})  [target is blank]"
echo "   backup:        $BK"
echo "   backup schema: ${SRC_SCHEMA:-unknown}"
echo "   loads into:    $DB_CONTAINER / $POSTGRES_DB , $UPLOAD_DIR , $STATIC_DIR"
echo "   schema:        $B_REV (matches $ENV code head — migrations will be a no-op)"
echo "   after restore: $([ -n "${NO_RESTART:-}" ] && echo 'server left STOPPED' || echo "start $SERVER_CONTAINER")"
[ -n "$SK_NOTE" ] && echo "   $SK_NOTE"
echo "============================================================"
if [ -z "${FORCE:-}" ]; then
    read -r -p "Type the target env name '$ENV' to proceed: " ans
    [ "$ans" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# Defensive: ensure the server isn't writing while we load.
docker stop "$SERVER_CONTAINER" >/dev/null 2>&1 || true

# --- 1. Load the dump into the empty database ---
echo "==> Restoring database dump ..."
if ! docker exec -i "$DB_CONTAINER" \
        pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner <"$BK/db.dump"; then
    echo "WARN: pg_restore exited non-zero (often harmless owner/role notices with --no-owner); review output above."
fi

# --- 2. Extract the uploaded-media + static files into the empty dirs ---
echo "==> Restoring uploaded media -> $UPLOAD_DIR ..."
mkdir -p "$UPLOAD_DIR"
tar -xzf "$BK/uploads.tgz" -C "$UPLOAD_DIR"
if [ -f "$BK/static.tgz" ]; then
    echo "==> Restoring static assets -> $STATIC_DIR ..."
    mkdir -p "$STATIC_DIR"
    tar -xzf "$BK/static.tgz" -C "$STATIC_DIR"
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
