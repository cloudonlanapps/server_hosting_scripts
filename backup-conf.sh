#!/bin/bash
set -euo pipefail

# Usage: ./backup-conf.sh <conf-file> <env>
#
# Point-in-time backup of a deployed environment's PostgreSQL database AND its
# uploaded-media / static directories. Reads PROJECT and the per-env branch
# from the host conf file (same conf as deploy-conf.sh).
#
# The DB is dumped from INSIDE the postgres container (version-matched
# pg_dump, no host port / DB password needed — the container's local socket
# trusts in-container connections) in custom format (-Fc). The upload/static
# dirs are copied VERBATIM (rsync -a) into the backup so they can be browsed
# and diffed without unpacking. A deterministic per-table content checksum is
# also written so the DB can be verified later (a repeated pg_dump is NOT
# byte-identical; the checksums are). See verify-conf.sh.
#
# LOCAL vs REMOTE
#   Default: everything runs on THIS machine (the deployment host).
#   REMOTE=1: run the dump/copy against a remote host over SSH and land the
#   artifacts LOCALLY (off-site pull). SSH details default to the conf's
#   SSH_USER / SSH_HOST / SSH_PORT; override with BACKUP_SSH_USER / _HOST / _PORT.
#
# Output (override the root with BACKUP_ROOT=...):
#   ${BACKUP_ROOT:-$HOME/<project>_backups}/<project>-<env>/<UTC-timestamp>/
#     ├── db.dump        pg_dump custom format (restorable)
#     ├── db.checksums   per-table: name|rowcount|content-hash (for verify)
#     ├── uploads/       verbatim copy of UPLOAD_DIR
#     ├── static/        verbatim copy of STATIC_DIR (if present)
#     └── MANIFEST.txt   what/when/where + alembic schema version + sizes

if [ $# -ne 2 ]; then
    echo "Usage: $0 <conf-file> <env>"
    exit 1
fi

CONF_FILE="$1"
ENV="$2"

if [ ! -f "$CONF_FILE" ]; then echo "ERROR: Conf file not found: $CONF_FILE"; exit 1; fi

# shellcheck disable=SC1090
source "$CONF_FILE"

if [ -z "${PROJECT:-}" ]; then echo "ERROR: $CONF_FILE must define PROJECT"; exit 1; fi
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 1; fi
ENV_OK=false
for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
if [ "$ENV_OK" = false ]; then echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"; exit 1; fi

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"
GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 1; fi

# --- Where do docker/copy run: locally or over SSH? ---
REMOTE_MODE=0
SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${REMOTE_SSH_HOST:-${BACKUP_SSH_HOST:-${SSH_HOST:-}}}"
    R_USER="${REMOTE_SSH_USER:-${BACKUP_SSH_USER:-${SSH_USER:-}}}"
    R_PORT="${REMOTE_SSH_PORT:-${BACKUP_SSH_PORT:-${SSH_PORT:-22}}}"
    if [ -z "$R_HOST" ]; then echo "ERROR: REMOTE=1 but no SSH host (set SSH_HOST or BACKUP_SSH_HOST)."; exit 1; fi
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"
    SSH_DESC="${SSH_TGT} (port ${R_PORT})"
fi

# runc <cmd>: run where the deployment lives (local shell or remote via SSH).
runc() {
    if [ "$REMOTE_MODE" = 1 ]; then ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"
    else bash -c "$1"; fi
}

# --- Derive container / data-dir names exactly like deploy.sh ---
if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    DATA_NAME="server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_NAME="server_${PROJECT}_${GIT_BRANCH}"
fi
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
DATA_REL=".local/share/${DATA_NAME}"          # relative to the target user's $HOME
DATA_DIR="\$HOME/${DATA_REL}"                  # literal $HOME — expands on the target
UPLOAD_DIR="${DATA_DIR}/uploads"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"
POSTGRES_USER="$PROJECT"

# rsync a target subdir (uploads/static) into the local backup, verbatim.
pull_dir() {  # <subdir>
    local sub="$1"
    mkdir -p "$BK/$sub"
    if [ "$REMOTE_MODE" = 1 ]; then
        rsync -a -e "ssh -p $R_PORT -o BatchMode=yes" "$SSH_TGT:${DATA_REL}/$sub/" "$BK/$sub/"
    else
        rsync -a "$HOME/${DATA_REL}/$sub/" "$BK/$sub/"
    fi
}

# --- Preconditions (checked on the target) ---
if [ "$REMOTE_MODE" = 1 ]; then
    ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null \
        || { echo "ERROR: cannot SSH to $SSH_DESC (need key-based access)."; exit 1; }
fi
runc "command -v docker >/dev/null" || { echo "ERROR: docker not found on $SSH_DESC."; exit 1; }
if ! runc "docker inspect -f '{{.State.Running}}' '$DB_CONTAINER' 2>/dev/null" | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running on $SSH_DESC."
    exit 1
fi
runc "test -d \"$UPLOAD_DIR\"" || { echo "ERROR: upload dir not found on $SSH_DESC: $UPLOAD_DIR"; exit 1; }
HAS_STATIC=0
if runc "test -d \"$STATIC_DIR\""; then HAS_STATIC=1; fi
command -v rsync >/dev/null || { echo "ERROR: rsync not found locally."; exit 1; }

# --- Backup destination (timestamped, LOCAL, outside the repo) ---
TS="$(date -u +%Y%m%d_%H%M%SZ)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/${PROJECT}_backups}"
BK="${BACKUP_ROOT}/${PROJECT}-${ENV}/${TS}"
mkdir -p "$BK"

echo "==> Backing up ${PROJECT} [${ENV}] (branch: ${GIT_BRANCH:-repo default}) from ${SSH_DESC}"
echo "    DB container: $DB_CONTAINER   DB/user: $POSTGRES_DB"
echo "    Destination:  $BK  (local)"

# --- 1. Database dump (custom format), straight out of the container ---
echo "==> Dumping database..."
runc "docker exec '$DB_CONTAINER' pg_dump -U '$POSTGRES_USER' -d '$POSTGRES_DB' -Fc --no-owner --no-privileges" >"$BK/db.dump"
if [ ! -s "$BK/db.dump" ] || ! head -c5 "$BK/db.dump" | LC_ALL=C grep -q 'PGDMP'; then
    echo "ERROR: db.dump is empty or not a valid pg_dump custom-format archive."
    exit 1
fi

ALEMBIC_VERSION="$(runc "docker exec '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tAc 'SELECT version_num FROM alembic_version'" 2>/dev/null | tr -d '[:space:]' || true)"

# --- 2. Deterministic per-table content checksums (for verify) ---
# For each public table: name|rowcount|md5 of its rows hashed order-independently.
echo "==> Computing DB content checksums..."
read -r -d '' CHECKSUM_SQL <<'SQL' || true
SELECT format(
  'SELECT %L, count(*), md5(coalesce(string_agg(md5(r::text), '''' ORDER BY md5(r::text)), '''')) FROM %I r',
  table_name, table_name)
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
\gexec
SQL
runc "docker exec -i '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tA -q" <<<"$CHECKSUM_SQL" \
    | LC_ALL=C sort >"$BK/db.checksums"

# --- 3. Uploaded media (verbatim) + served static assets (verbatim) ---
echo "==> Copying uploaded media (verbatim)..."
pull_dir uploads
STATIC_SIZE="(absent)"
if [ "$HAS_STATIC" = 1 ]; then
    echo "==> Copying static assets (verbatim)..."
    pull_dir static
    STATIC_SIZE="$(du -sh "$BK/static" | cut -f1)"
fi

# --- 4. Manifest ---
DB_SIZE="$(du -h "$BK/db.dump" | cut -f1)"
UPLOADS_SIZE="$(du -sh "$BK/uploads" | cut -f1)"
TABLE_COUNT="$(grep -c . "$BK/db.checksums" || true)"
cat >"$BK/MANIFEST.txt" <<EOF
project:          $PROJECT
env:              $ENV
git_branch:       ${GIT_BRANCH:-(repo default)}
source_host:      $SSH_DESC
db_container:     $DB_CONTAINER
postgres_db:      $POSTGRES_DB
alembic_version:  ${ALEMBIC_VERSION:-(unknown)}
created_utc:      $TS
db.dump:          $DB_SIZE (pg_dump -Fc, --no-owner --no-privileges)
db.checksums:     ${TABLE_COUNT} tables
uploads/:         $UPLOADS_SIZE (verbatim)
static/:          $STATIC_SIZE
EOF

echo "==> Done."
echo "    db.dump:    $DB_SIZE   tables: $TABLE_COUNT   schema: ${ALEMBIC_VERSION:-unknown}"
echo "    uploads/:   $UPLOADS_SIZE   static/: $STATIC_SIZE"
echo "    -> $BK"
