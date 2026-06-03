#!/bin/bash
set -uo pipefail   # NOT -e: we want to run every check and report a summary

# Usage: ./verify-conf.sh <conf-file> <env> <backup-dir>
#
# Verify whether a backup (from backup-conf.sh) still matches the CURRENT state
# of <env>. Runs on this host.
#
#   Database — recompute the per-table content checksums from the live DB and
#     diff them against the backup's db.checksums (a re-dump is NOT byte-stable,
#     but these checksums are, so this is exact for content). Also compares the
#     alembic_version.
#   Files — diff -rq the backup's verbatim uploads/ and static/ folders against
#     the live UPLOAD_DIR / STATIC_DIR.
#
# Exit code 0 = backup matches live state; 1 = drift (differences listed); 2 =
# usage/precondition error. Useful right after a backup (should be clean) or to
# detect whether an env has changed since a backup was taken.

if [ $# -ne 3 ]; then echo "Usage: $0 <conf-file> <env> <backup-dir>"; exit 2; fi
CONF_FILE="$1"; ENV="$2"; BK="${3%/}"

[ -f "$CONF_FILE" ] || { echo "ERROR: Conf file not found: $CONF_FILE"; exit 2; }
[ -d "$BK" ] || { echo "ERROR: Backup dir not found: $BK"; exit 2; }
[ -f "$BK/db.checksums" ] || { echo "ERROR: Backup has no db.checksums: $BK"; exit 2; }
[ -d "$BK/uploads" ] || { echo "ERROR: Backup has no uploads/ folder: $BK"; exit 2; }

# shellcheck disable=SC1090
source "$CONF_FILE"
[ -n "${PROJECT:-}" ] || { echo "ERROR: $CONF_FILE must define PROJECT"; exit 2; }
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 2; fi
ENV_OK=false; for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
[ "$ENV_OK" = true ] || { echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"; exit 2; }

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"; GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 2; fi

DATA_BASE="${HOME}/.local/share"
if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    DATA_DIR="${DATA_BASE}/server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_DIR="${DATA_BASE}/server_${PROJECT}_${GIT_BRANCH}"
fi
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
UPLOAD_DIR="${DATA_DIR}/uploads"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"; POSTGRES_USER="$PROJECT"

command -v docker >/dev/null || { echo "ERROR: docker not found — run on the host."; exit 2; }
if ! docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running."; exit 2
fi

FAIL=0
echo "==> Verifying backup vs live ${ENV}"
echo "    backup: $BK"

# --- 1. alembic_version ---
manifest_get() { awk -F': *' -v k="$1" '$1==k {print $2; exit}' "$BK/MANIFEST.txt"; }
BK_SCHEMA="$(manifest_get alembic_version)"
LIVE_SCHEMA="$(docker exec "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    'SELECT version_num FROM alembic_version' 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$BK_SCHEMA" = "$LIVE_SCHEMA" ]; then
    echo "[ OK ] schema: $LIVE_SCHEMA"
else
    echo "[FAIL] schema: backup=$BK_SCHEMA  live=$LIVE_SCHEMA"; FAIL=1
fi

# --- 2. Database content (recompute live checksums, diff vs backup) ---
read -r -d '' CHECKSUM_SQL <<'SQL' || true
SELECT format(
  'SELECT %L, count(*), md5(coalesce(string_agg(md5(r::text), '''' ORDER BY md5(r::text)), '''')) FROM %I r',
  table_name, table_name)
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;
\gexec
SQL
LIVE_SUMS="$(docker exec -i "$DB_CONTAINER" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -q <<<"$CHECKSUM_SQL" | LC_ALL=C sort)"
DB_DIFF="$(diff <(LC_ALL=C sort "$BK/db.checksums") <(printf '%s\n' "$LIVE_SUMS") || true)"
if [ -z "$DB_DIFF" ]; then
    echo "[ OK ] database: all tables match (< backup  > live)"
else
    echo "[FAIL] database differs (< backup  > live):"
    printf '%s\n' "$DB_DIFF" | sed 's/^/        /'
    FAIL=1
fi

# --- 3. Files (verbatim folder diff) ---
verify_dir() {  # <backup-subdir> <live-dir> <label>
    local b="$1" live="$2" label="$3"
    if [ ! -d "$b" ]; then echo "[ -- ] $label: not in backup (skipped)"; return; fi
    if [ ! -d "$live" ]; then echo "[FAIL] $label: live dir missing ($live)"; FAIL=1; return; fi
    local out; out="$(diff -rq "$b" "$live" 2>&1 || true)"
    if [ -z "$out" ]; then
        echo "[ OK ] $label: identical"
    else
        echo "[FAIL] $label differs:"; printf '%s\n' "$out" | sed 's/^/        /'; FAIL=1
    fi
}
verify_dir "$BK/uploads" "$UPLOAD_DIR" "uploads/"
verify_dir "$BK/static"  "$STATIC_DIR" "static/"

echo "============================================================"
if [ "$FAIL" = 0 ]; then echo "RESULT: MATCH — backup equals live ${ENV}."; exit 0
else echo "RESULT: DRIFT — backup differs from live ${ENV} (see above)."; exit 1; fi
