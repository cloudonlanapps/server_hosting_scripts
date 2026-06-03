#!/bin/bash
set -euo pipefail

# Usage: ./backup-conf.sh <conf-file> <env>
#
# Point-in-time backup of a deployed environment's PostgreSQL database AND its
# uploaded-media / static directories. Reads PROJECT and the per-env branch
# from the host conf file (same conf as deploy-conf.sh).
#
# The DB is dumped from INSIDE the postgres container (version-matched
# pg_dump, no host port needed, no DB password needed — the container's local
# socket trusts in-container connections) in custom format (-Fc), which is
# compressed and restorable with pg_restore. The upload/static dirs are tarred
# from the host bind-mounts. Artifacts are always written LOCALLY (see below);
# nothing is written into this repo.
#
# LOCAL vs REMOTE
#   By default everything runs on THIS machine (the deployment host).
#   Set REMOTE=1 to run the dump/tar on a remote host over SSH and stream the
#   artifacts back to the local machine (off-site / pull backup). SSH details
#   default to the conf's SSH_USER / SSH_HOST / SSH_PORT and can be overridden
#   with BACKUP_SSH_USER / BACKUP_SSH_HOST / BACKUP_SSH_PORT.
#
# Required conf vars (see host_icehockeymaharashtra_in.conf):
#   PROJECT, ENVS, <env>_GIT_BRANCH (for non-dev envs)
#   For REMOTE=1: SSH_HOST (+ SSH_USER / SSH_PORT) or the BACKUP_SSH_* overrides
#
# Output (override the root with BACKUP_ROOT=...):
#   ${BACKUP_ROOT:-$HOME/<project>_backups}/<project>-<env>/<UTC-timestamp>/
#     ├── db.dump        pg_dump custom format
#     ├── uploads.tgz    gzipped tar of the UPLOAD_DIR (uploaded media — critical)
#     ├── static.tgz     gzipped tar of the STATIC_DIR (served assets), if present
#     └── MANIFEST.txt    what/when/where + alembic schema version + sizes

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

if [ -z "${PROJECT:-}" ]; then
    echo "ERROR: $CONF_FILE must define PROJECT"
    exit 1
fi
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then
    echo "ERROR: $CONF_FILE must define ENVS=(...) with at least one entry"
    exit 1
fi
ENV_OK=false
for e in "${ENVS[@]}"; do
    [ "$e" = "$ENV" ] && ENV_OK=true && break
done
if [ "$ENV_OK" = false ]; then
    echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"
    exit 1
fi

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"
GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"
    exit 1
fi

# --- Where do docker/tar run: locally or over SSH? ---
REMOTE_MODE=0
SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${BACKUP_SSH_HOST:-${SSH_HOST:-}}"
    R_USER="${BACKUP_SSH_USER:-${SSH_USER:-}}"
    R_PORT="${BACKUP_SSH_PORT:-${SSH_PORT:-22}}"
    if [ -z "$R_HOST" ]; then
        echo "ERROR: REMOTE=1 but no SSH host. Set SSH_HOST in the conf or BACKUP_SSH_HOST."
        exit 1
    fi
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"
    SSH_DESC="${SSH_TGT} (port ${R_PORT})"
fi

# runc <command-string>: run a command where the deployment lives (local shell
# or remote over SSH). Paths below use a literal $HOME so they expand on the
# target, making the same command string correct in both modes.
runc() {
    if [ "$REMOTE_MODE" = 1 ]; then
        ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"
    else
        bash -c "$1"
    fi
}

# --- Derive container / data-dir names exactly like deploy.sh (literal $HOME
#     so the path resolves on whichever host actually runs the commands) ---
if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    if [ -n "$GIT_BRANCH" ]; then
        DATA_DIR="\$HOME/.local/share/server_dev_${PROJECT}_${GIT_BRANCH}"
    else
        DATA_DIR="\$HOME/.local/share/server_dev_${PROJECT}"
    fi
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_DIR="\$HOME/.local/share/server_${PROJECT}_${GIT_BRANCH}"
fi

DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
# Bind-mount host paths from docker-compose.yml:
#   ${DATA_DIR}/uploads -> /data/uploads (UPLOAD_DIR, the uploaded media)
#   ${DATA_DIR}/static  -> /data/static  (STATIC_DIR, served assets)
UPLOAD_DIR="${DATA_DIR}/uploads"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"
POSTGRES_USER="$PROJECT"

# --- Preconditions (checked on the target) ---
if [ "$REMOTE_MODE" = 1 ]; then
    if ! ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null; then
        echo "ERROR: cannot SSH to $SSH_DESC (need key-based access / BatchMode)."
        exit 1
    fi
fi
if ! runc "command -v docker >/dev/null"; then
    echo "ERROR: docker not found on $SSH_DESC."
    exit 1
fi
if ! runc "docker inspect -f '{{.State.Running}}' '$DB_CONTAINER' 2>/dev/null" | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running on $SSH_DESC."
    runc "docker ps --format '    {{.Names}}'" || true
    exit 1
fi
if ! runc "test -d \"$UPLOAD_DIR\""; then
    echo "ERROR: upload dir not found on $SSH_DESC: $UPLOAD_DIR"
    exit 1
fi
HAS_STATIC=0
if runc "test -d \"$STATIC_DIR\""; then HAS_STATIC=1; fi

# --- Backup destination (timestamped, LOCAL, outside the repo) ---
TS="$(date -u +%Y%m%d_%H%M%SZ)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/${PROJECT}_backups}"
BK="${BACKUP_ROOT}/${PROJECT}-${ENV}/${TS}"
mkdir -p "$BK"

echo "==> Backing up ${PROJECT} [${ENV}] (branch: ${GIT_BRANCH:-repo default}) from ${SSH_DESC}"
echo "    DB container: $DB_CONTAINER   DB/user: $POSTGRES_DB"
echo "    Upload dir:   $UPLOAD_DIR"
echo "    Static dir:   $STATIC_DIR"
echo "    Destination:  $BK  (local)"

# --- 1. Database dump (custom format), straight out of the container ---
echo "==> Dumping database..."
runc "docker exec '$DB_CONTAINER' pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' -Fc --no-owner --no-privileges" >"$BK/db.dump"

# Verify locally: non-empty and carries the pg_dump custom-format magic.
if [ ! -s "$BK/db.dump" ] || ! head -c5 "$BK/db.dump" | LC_ALL=C grep -q 'PGDMP'; then
    echo "ERROR: db.dump is empty or not a valid pg_dump custom-format archive."
    exit 1
fi

# Record the schema version captured by this backup.
ALEMBIC_VERSION="$(runc "docker exec '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tAc 'SELECT version_num FROM alembic_version'" 2>/dev/null | tr -d '[:space:]' || true)"

# --- 2. Uploaded media (critical) + served static assets ---
echo "==> Archiving uploaded media..."
runc "tar -czf - -C \"$UPLOAD_DIR\" ." >"$BK/uploads.tgz"

STATIC_SIZE="(absent)"
if [ "$HAS_STATIC" = 1 ]; then
    echo "==> Archiving static assets..."
    runc "tar -czf - -C \"$STATIC_DIR\" ." >"$BK/static.tgz"
    STATIC_SIZE="$(du -h "$BK/static.tgz" | cut -f1)"
fi

# --- 3. Manifest ---
DB_SIZE="$(du -h "$BK/db.dump" | cut -f1)"
UPLOADS_SIZE="$(du -h "$BK/uploads.tgz" | cut -f1)"
cat >"$BK/MANIFEST.txt" <<EOF
project:          $PROJECT
env:              $ENV
git_branch:       ${GIT_BRANCH:-(repo default)}
source_host:      $SSH_DESC
db_container:     $DB_CONTAINER
postgres_db:      $POSTGRES_DB
alembic_version:  ${ALEMBIC_VERSION:-(unknown)}
created_utc:      $TS
source_upload:    $UPLOAD_DIR
source_static:    $STATIC_DIR
db.dump:          $DB_SIZE (pg_dump -Fc, --no-owner --no-privileges)
uploads.tgz:      $UPLOADS_SIZE
static.tgz:       $STATIC_SIZE

Restore (into an isolated env for rehearsal, NOT over prod):
  restore-conf.sh $CONF_FILE <target-env> "$BK"
EOF

echo "==> Done."
echo "    db.dump:     $DB_SIZE"
echo "    uploads.tgz: $UPLOADS_SIZE"
echo "    static.tgz:  $STATIC_SIZE"
echo "    schema:      ${ALEMBIC_VERSION:-(unknown)}"
echo "    -> $BK"
