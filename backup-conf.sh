#!/bin/bash
set -euo pipefail

# Usage: ./backup-conf.sh <conf-file> <env>
#
# Point-in-time backup of a deployed environment's PostgreSQL database AND its
# uploaded-files/static directory. Reads PROJECT and per-env branch from the
# host conf file (same conf as deploy-conf.sh) and the database password from
# the 'pass' password manager.
#
# The DB is dumped from INSIDE the postgres container (version-matched
# pg_dump, no host port needed) in custom format (-Fc), which is compressed
# and restorable with pg_restore. The static dir is tarred from the host
# bind-mount. Nothing is written into this repo.
#
# Required conf vars (see host_icehockeymaharashtra_in.conf):
#   PROJECT, ENVS, <env>_GIT_BRANCH (for non-dev envs)
# Required pass entry (prefix defaults to $PROJECT):
#   <prefix>/<env>/postgres-password
#
# Output (override the root with BACKUP_ROOT=...):
#   ${BACKUP_ROOT:-$HOME/<project>_backups}/<project>-<env>/<UTC-timestamp>/
#     ├── db.dump        pg_dump custom format
#     ├── static.tgz     gzipped tar of the uploads/static dir
#     └── MANIFEST.txt    what/when/where + alembic schema version + sizes

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

for var in PROJECT; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $CONF_FILE must define $var"
        exit 1
    fi
done

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

PASS_PREFIX="${PASS_PREFIX:-$PROJECT}"

if ! command -v pass &>/dev/null; then
    echo "ERROR: 'pass' (password manager) is not installed."
    exit 1
fi

PW_KEY="${PASS_PREFIX}/${ENV}/postgres-password"
if ! pass show "$PW_KEY" &>/dev/null; then
    echo "ERROR: Missing secret in pass store: $PW_KEY"
    echo "  Add it with: pass insert $PW_KEY"
    exit 1
fi
POSTGRES_PASSWORD="$(pass show "$PW_KEY")"

# --- Derive container / data-dir names exactly like deploy.sh ---
DATA_BASE="${HOME}/.local/share"
if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    if [ -n "$GIT_BRANCH" ]; then
        DATA_DIR="${DATA_BASE}/server_dev_${PROJECT}_${GIT_BRANCH}"
    else
        DATA_DIR="${DATA_BASE}/server_dev_${PROJECT}"
    fi
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_DIR="${DATA_BASE}/server_${PROJECT}_${GIT_BRANCH}"
fi

DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"
POSTGRES_USER="$PROJECT"

# --- Preconditions ---
if ! command -v docker &>/dev/null; then
    echo "ERROR: docker not found — run this on the deployment host."
    exit 1
fi
if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running."
    echo "  Running containers:"
    docker ps --format '    {{.Names}}' || true
    exit 1
fi
if [ ! -d "$STATIC_DIR" ]; then
    echo "ERROR: static dir not found: $STATIC_DIR"
    exit 1
fi

# --- Backup destination (timestamped, outside the repo) ---
TS="$(date -u +%Y%m%d_%H%M%SZ)"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/${PROJECT}_backups}"
BK="${BACKUP_ROOT}/${PROJECT}-${ENV}/${TS}"
mkdir -p "$BK"

echo "==> Backing up ${PROJECT} [${ENV}] (branch: ${GIT_BRANCH:-repo default})"
echo "    DB container: $DB_CONTAINER   DB/user: $POSTGRES_DB"
echo "    Static dir:   $STATIC_DIR"
echo "    Destination:  $BK"

# --- 1. Database dump (custom format), straight out of the container ---
echo "==> Dumping database..."
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -Fc --no-owner --no-privileges >"$BK/db.dump"

# Verify the dump is structurally readable (uses the container's pg_restore).
if ! docker exec -i "$DB_CONTAINER" pg_restore -l >/dev/null <"$BK/db.dump"; then
    echo "ERROR: dump verification failed (pg_restore -l)."
    exit 1
fi

# Record the schema version captured by this backup.
ALEMBIC_VERSION="$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    'SELECT version_num FROM alembic_version' 2>/dev/null | tr -d '[:space:]' || true)"

# --- 2. Uploaded files / static dir ---
echo "==> Archiving static/uploads..."
tar -czf "$BK/static.tgz" -C "$STATIC_DIR" .

# --- 3. Manifest ---
DB_SIZE="$(du -h "$BK/db.dump" | cut -f1)"
STATIC_SIZE="$(du -h "$BK/static.tgz" | cut -f1)"
cat >"$BK/MANIFEST.txt" <<EOF
project:          $PROJECT
env:              $ENV
git_branch:       ${GIT_BRANCH:-(repo default)}
db_container:     $DB_CONTAINER
postgres_db:      $POSTGRES_DB
alembic_version:  ${ALEMBIC_VERSION:-(unknown)}
created_utc:      $TS
source_static:    $STATIC_DIR
db.dump:          $DB_SIZE (pg_dump -Fc, --no-owner --no-privileges)
static.tgz:       $STATIC_SIZE

Restore (into an isolated DB for rehearsal, NOT over prod):
  createdb -h HOST -p PORT -U USER restore_target
  pg_restore -h HOST -p PORT -U USER -d restore_target --no-owner "$BK/db.dump"
  mkdir -p /path/to/restore_static && tar -xzf "$BK/static.tgz" -C /path/to/restore_static
EOF

echo "==> Done."
echo "    db.dump:    $DB_SIZE"
echo "    static.tgz: $STATIC_SIZE"
echo "    schema:     ${ALEMBIC_VERSION:-(unknown)}"
echo "    -> $BK"
