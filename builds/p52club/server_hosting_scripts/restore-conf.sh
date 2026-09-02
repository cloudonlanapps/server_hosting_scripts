#!/bin/bash
set -euo pipefail

# Usage: ./restore-conf.sh <conf-file> <target-env> <backup-dir>
#
# Load a backup (produced by backup-conf.sh) INTO a deployed environment of
# the SAME project — e.g. a prod backup into beta, or beta into prod.
#
# Single purpose: it ONLY loads, and REFUSES unless the target is already
# blank (empty database AND empty upload/static dirs). To replace a populated
# env, blank it first with reset-conf.sh (`just reset <env>`), or use the
# `just restore-clean` orchestrator (backup -> reset -> restore). It never
# drops a database or deletes files.
#
# FAIL-SAFE schema check: the backup's alembic revision must EXACTLY equal the
# target env's code migration head, or restore refuses (no silent up/downgrade).
#
# LOCAL vs REMOTE
#   Default: target is on THIS host. REMOTE=1: target is a remote host over SSH
#   (SSH_USER/SSH_HOST/SSH_PORT from the conf; override REMOTE_SSH_{USER,HOST,
#   PORT}). The backup is always read from the LOCAL <backup-dir>; the DB load
#   and file copy are streamed to the target.
#
# Knobs:
#   FORCE=1       skip the interactive confirmation prompt
#   NO_RESTART=1  load data but leave the server stopped (inspect first)
#   CHECK_ONLY=1  run validations (incl. the schema check) and exit without
#                 loading; skips the empty-target check (used by restore-clean).
#
# No DB password needed: pg_restore runs via `docker exec` over the trusted
# local socket of the target's postgres container.

if [ $# -ne 3 ]; then echo "Usage: $0 <conf-file> <target-env> <backup-dir>"; exit 1; fi
CONF_FILE="$1"; ENV="$2"; BK="${3%/}"

[ -f "$CONF_FILE" ] || { echo "ERROR: Conf file not found: $CONF_FILE"; exit 1; }
[ -d "$BK" ] || { echo "ERROR: Backup dir not found: $BK"; exit 1; }
for f in db.dump MANIFEST.txt; do
    [ -f "$BK/$f" ] || { echo "ERROR: Backup dir is missing $f: $BK"; exit 1; }
done
[ -d "$BK/uploads" ] || { echo "ERROR: Backup dir is missing the uploads/ folder: $BK"; exit 1; }

# shellcheck disable=SC1090
source "$CONF_FILE"
[ -n "${PROJECT:-}" ] || { echo "ERROR: $CONF_FILE must define PROJECT"; exit 1; }
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 1; fi
ENV_OK=false; for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
[ "$ENV_OK" = true ] || { echo "ERROR: Unknown target env '$ENV'. Allowed: ${ENVS[*]}"; exit 1; }

PASS_PREFIX="${PASS_PREFIX:-$PROJECT}"

manifest_get() { awk -F': *' -v k="$1" '$1==k {print $2; exit}' "$BK/MANIFEST.txt"; }
SRC_PROJECT="$(manifest_get project)"; SRC_ENV="$(manifest_get env)"; SRC_SCHEMA="$(manifest_get alembic_version)"
if [ -n "$SRC_PROJECT" ] && [ "$SRC_PROJECT" != "$PROJECT" ]; then
    echo "ERROR: backup is from project '$SRC_PROJECT' but conf PROJECT is '$PROJECT'. Cross-project restore unsupported."
    exit 1
fi

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"; GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 1; fi

# --- Target: local or remote over SSH ---
REMOTE_MODE=0; SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${REMOTE_SSH_HOST:-${SSH_HOST:-}}"; R_USER="${REMOTE_SSH_USER:-${SSH_USER:-}}"; R_PORT="${REMOTE_SSH_PORT:-${SSH_PORT:-22}}"
    [ -n "$R_HOST" ] || { echo "ERROR: REMOTE=1 but no SSH host (set SSH_HOST or REMOTE_SSH_HOST)."; exit 1; }
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"; SSH_DESC="$SSH_TGT (port $R_PORT)"
fi
runc() { if [ "$REMOTE_MODE" = 1 ]; then ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"; else bash -c "$1"; fi; }
rsync_to_target() {  # <local-src/> <subdir>
    runc "mkdir -p \"$DATA_DIR/$2\""
    if [ "$REMOTE_MODE" = 1 ]; then rsync -a -e "ssh -p $R_PORT -o BatchMode=yes" "$1" "$SSH_TGT:.local/share/${DATA_NAME}/$2/"
    else rsync -a "$1" "$HOME/.local/share/${DATA_NAME}/$2/"; fi
}

if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"; DATA_NAME="server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"; DATA_NAME="server_${PROJECT}_${GIT_BRANCH}"
fi
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
SERVER_CONTAINER="${COMPOSE_PROJECT_NAME}-server"
DATA_DIR="\$HOME/.local/share/${DATA_NAME}"
UPLOAD_DIR="${DATA_DIR}/uploads"; STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"; POSTGRES_USER="$PROJECT"

# --- Preconditions ---
if [ "$REMOTE_MODE" = 1 ]; then
    ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null || { echo "ERROR: cannot SSH to $SSH_DESC."; exit 1; }
fi
runc "command -v docker >/dev/null" || { echo "ERROR: docker not found on $SSH_DESC."; exit 1; }
if ! runc "docker inspect -f '{{.State.Running}}' '$DB_CONTAINER' 2>/dev/null" | grep -q true; then
    echo "ERROR: target postgres container '$DB_CONTAINER' is not running on $SSH_DESC. Deploy it first (just deploy $ENV)."
    exit 1
fi

# --- FAIL-SAFE: backup schema must EXACTLY equal the target code's head ---
echo "==> Verifying schema compatibility ..."
B_REV="$SRC_SCHEMA"
if [ -z "$B_REV" ] || [ "$B_REV" = "(unknown)" ]; then echo "ERROR: backup MANIFEST has no alembic_version — cannot verify. Refusing."; exit 1; fi
IMAGE="$(runc "docker inspect -f '{{.Config.Image}}' '$SERVER_CONTAINER' 2>/dev/null" || true)"
[ -n "$IMAGE" ] || { echo "ERROR: server container '$SERVER_CONTAINER' not found on $SSH_DESC; deploy $ENV first."; exit 1; }
CODE_HEADS="$(runc "docker run --rm --entrypoint sh -e DATABASE_URL='postgresql+asyncpg://u:u@localhost:5432/u' -e SECRET_KEY=x -e UPLOAD_DIR=/tmp -e STATIC_DIR=/tmp -e PROJECT_NAME='$PROJECT' '$IMAGE' -c 'cd /app && uv run alembic heads 2>/dev/null'" | awk '{print $1}' | grep -E '^[0-9A-Za-z_]+$' || true)"
[ -n "$CODE_HEADS" ] || { echo "ERROR: could not determine $ENV code migration head from image $IMAGE. Refusing."; exit 1; }
N_HEADS="$(printf '%s\n' "$CODE_HEADS" | grep -c .)"
if [ "$N_HEADS" -ne 1 ] || [ "$CODE_HEADS" != "$B_REV" ]; then
    echo "ERROR: schema mismatch — restore refused (fail-safe)."
    echo "    backup schema:   $B_REV   (from ${SRC_ENV:-?})"
    echo "    $ENV code head:  $(printf '%s ' $CODE_HEADS)"
    echo "  Restore only proceeds when the backup schema EQUALS the target code head."
    exit 1
fi
echo "    OK: backup schema $B_REV matches $ENV code head."

if [ -n "${CHECK_ONLY:-}" ]; then echo "==> CHECK_ONLY: compatibility verified; not loading."; exit 0; fi

# --- Refuse a non-empty target (this script does not blank anything) ---
if ! runc "docker exec -i '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d postgres -tA" <<<"SELECT 1 FROM pg_database WHERE datname='$POSTGRES_DB';" | grep -q 1; then
    echo "ERROR: database '$POSTGRES_DB' does not exist on $ENV. Blank it first: just reset $ENV"; exit 1
fi
TABLE_COUNT="$(runc "docker exec -i '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tA" <<<"SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema');" | tr -d '[:space:]')"
if [ "${TABLE_COUNT:-0}" != "0" ]; then
    echo "ERROR: target DB '$POSTGRES_DB' is NOT empty (${TABLE_COUNT} tables). Blank it first: just reset $ENV"
    echo "  (or: just restore-clean $ENV $BK)"; exit 1
fi
for d in "$UPLOAD_DIR" "$STATIC_DIR"; do
    if [ -n "$(runc "[ -d \"$d\" ] && find \"$d\" -mindepth 1 -print -quit 2>/dev/null" || true)" ]; then
        echo "ERROR: target dir is NOT empty: $d  — blank it first: just reset $ENV"; exit 1
    fi
done

# --- SECRET_KEY mismatch warning (uses LOCAL pass; best-effort) ---
SK_NOTE=""
if command -v pass &>/dev/null && [ -n "$SRC_ENV" ]; then
    if pass show "${PASS_PREFIX}/${SRC_ENV}/secret-key" &>/dev/null && pass show "${PASS_PREFIX}/${ENV}/secret-key" &>/dev/null; then
        [ "$(pass show "${PASS_PREFIX}/${SRC_ENV}/secret-key")" != "$(pass show "${PASS_PREFIX}/${ENV}/secret-key")" ] \
            && SK_NOTE="WARNING: target secret-key ($ENV) differs from source ($SRC_ENV). Encrypted media will NOT decrypt on $ENV unless redeployed with the source's key."
    else
        SK_NOTE="NOTE: could not compare secret-keys (missing pass entry) — encrypted media may not decrypt if keys differ."
    fi
fi

# --- Confirm ---
echo "============================================================"
echo " RESTORE  ${SRC_ENV:-?} backup  ->  ${ENV}  (project ${PROJECT})  on ${SSH_DESC}  [target is blank]"
echo "   backup:        $BK"
echo "   schema:        $B_REV (matches $ENV code head — migrations will be a no-op)"
echo "   loads into:    $DB_CONTAINER / $POSTGRES_DB , $UPLOAD_DIR , $STATIC_DIR"
echo "   after restore: $([ -n "${NO_RESTART:-}" ] && echo 'server left STOPPED' || echo "start $SERVER_CONTAINER")"
[ -n "$SK_NOTE" ] && echo "   $SK_NOTE"
echo "============================================================"
if [ -z "${FORCE:-}" ]; then
    read -r -p "Type the target env name '$ENV' to proceed: " ans
    [ "$ans" = "$ENV" ] || { echo "Aborted."; exit 1; }
fi

# Defensive: ensure the server isn't writing while we load.
runc "docker stop '$SERVER_CONTAINER' >/dev/null 2>&1 || true"

# --- 1. Load the dump into the empty database ---
echo "==> Restoring database dump ..."
if ! runc "docker exec -i '$DB_CONTAINER' pg_restore -U '$POSTGRES_USER' -d '$POSTGRES_DB' --no-owner" <"$BK/db.dump"; then
    echo "WARN: pg_restore exited non-zero (often harmless owner/role notices with --no-owner); review output above."
fi

# --- 2. Copy the uploaded-media + static files (verbatim) into the empty dirs ---
echo "==> Restoring uploaded media -> $UPLOAD_DIR ..."
rsync_to_target "$BK/uploads/" uploads
if [ -d "$BK/static" ]; then
    echo "==> Restoring static assets -> $STATIC_DIR ..."
    rsync_to_target "$BK/static/" static
fi

# --- 3. Bring the server back (re-runs migrations on boot) ---
if [ -n "${NO_RESTART:-}" ]; then
    echo "==> NO_RESTART set: leaving $SERVER_CONTAINER stopped."
    echo "    Start it with: docker start $SERVER_CONTAINER"
else
    echo "==> Starting $SERVER_CONTAINER ..."
    runc "docker start '$SERVER_CONTAINER' >/dev/null"
    sleep 2
    runc "docker logs --tail=30 '$SERVER_CONTAINER' 2>&1" || true
fi

echo "==> Restore complete: ${SRC_ENV:-?} (schema ${SRC_SCHEMA:-unknown}) -> ${ENV} on ${SSH_DESC}."
echo "    Watch:  ${REMOTE_MODE:+ssh -p $R_PORT $SSH_TGT }docker logs -f $SERVER_CONTAINER"
