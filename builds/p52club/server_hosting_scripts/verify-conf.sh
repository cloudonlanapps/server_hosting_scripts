#!/bin/bash
set -uo pipefail   # NOT -e: run every check and report a summary

# Usage: ./verify-conf.sh <conf-file> <env> <backup-dir>
#
# Verify whether a backup (from backup-conf.sh) still matches the CURRENT state
# of <env>.
#
#   Database — recompute the per-table content checksums from the live DB and
#     diff them against the backup's db.checksums (a re-dump is not byte-stable,
#     but these checksums are). Also compares alembic_version.
#   Files — content-compare (rsync --checksum) the backup's verbatim uploads/
#     and static/ folders against the live UPLOAD_DIR / STATIC_DIR.
#
# LOCAL vs REMOTE
#   Default: <env> is on THIS host. REMOTE=1: <env> is a remote host over SSH
#   (SSH_USER/SSH_HOST/SSH_PORT from the conf; override REMOTE_SSH_{USER,HOST,
#   PORT}). The backup is read locally; live state is read from the target.
#
# Exit 0 = match, 1 = drift (differences listed), 2 = usage/precondition error.

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

# --- Target: local or remote over SSH ---
REMOTE_MODE=0; SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${REMOTE_SSH_HOST:-${SSH_HOST:-}}"; R_USER="${REMOTE_SSH_USER:-${SSH_USER:-}}"; R_PORT="${REMOTE_SSH_PORT:-${SSH_PORT:-22}}"
    [ -n "$R_HOST" ] || { echo "ERROR: REMOTE=1 but no SSH host (set SSH_HOST or REMOTE_SSH_HOST)."; exit 2; }
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"; SSH_DESC="$SSH_TGT (port $R_PORT)"
fi
runc() { if [ "$REMOTE_MODE" = 1 ]; then ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"; else bash -c "$1"; fi; }

if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"; DATA_NAME="server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"; DATA_NAME="server_${PROJECT}_${GIT_BRANCH}"
fi
DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
POSTGRES_DB="$PROJECT"; POSTGRES_USER="$PROJECT"

# --- Preconditions ---
if [ "$REMOTE_MODE" = 1 ]; then
    ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null || { echo "ERROR: cannot SSH to $SSH_DESC."; exit 2; }
fi
runc "command -v docker >/dev/null" || { echo "ERROR: docker not found on $SSH_DESC."; exit 2; }
if ! runc "docker inspect -f '{{.State.Running}}' '$DB_CONTAINER' 2>/dev/null" | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running on $SSH_DESC."; exit 2
fi

FAIL=0
echo "==> Verifying backup vs live ${ENV} (${SSH_DESC})"
echo "    backup: $BK"

# --- 1. alembic_version ---
manifest_get() { awk -F': *' -v k="$1" '$1==k {print $2; exit}' "$BK/MANIFEST.txt"; }
BK_SCHEMA="$(manifest_get alembic_version)"
LIVE_SCHEMA="$(runc "docker exec '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tAc 'SELECT version_num FROM alembic_version'" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$BK_SCHEMA" = "$LIVE_SCHEMA" ]; then echo "[ OK ] schema: $LIVE_SCHEMA"
else echo "[FAIL] schema: backup=$BK_SCHEMA  live=$LIVE_SCHEMA"; FAIL=1; fi

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
LIVE_SUMS="$(runc "docker exec -i '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d '$POSTGRES_DB' -tA -q" <<<"$CHECKSUM_SQL" | LC_ALL=C sort)"
DB_DIFF="$(diff <(LC_ALL=C sort "$BK/db.checksums") <(printf '%s\n' "$LIVE_SUMS") || true)"
if [ -z "$DB_DIFF" ]; then echo "[ OK ] database: all tables match (< backup  > live)"
else echo "[FAIL] database differs (< backup  > live):"; printf '%s\n' "$DB_DIFF" | sed 's/^/        /'; FAIL=1; fi

# --- 3. Files (content compare via rsync --checksum dry-run) ---
verify_dir() {  # <backup-subdir> <sub-name> <label>
    local b="$1" sub="$2" label="$3"
    [ -d "$b" ] || { echo "[ -- ] $label: not in backup (skipped)"; return; }
    if ! runc "test -d \"\$HOME/.local/share/${DATA_NAME}/$sub\""; then echo "[FAIL] $label: live dir missing"; FAIL=1; return; fi
    local out
    if [ "$REMOTE_MODE" = 1 ]; then
        out="$(rsync -ani --checksum --delete -e "ssh -p $R_PORT -o BatchMode=yes" "$b/" "$SSH_TGT:.local/share/${DATA_NAME}/$sub/" 2>/dev/null | grep -E '^(\*|[<>c])' || true)"
    else
        out="$(rsync -ani --checksum --delete "$b/" "$HOME/.local/share/${DATA_NAME}/$sub/" 2>/dev/null | grep -E '^(\*|[<>c])' || true)"
    fi
    if [ -z "$out" ]; then echo "[ OK ] $label: identical"
    else echo "[FAIL] $label differs (lines: >/c = in backup not matching live, * = extra on live):"; printf '%s\n' "$out" | sed 's/^/        /'; FAIL=1; fi
}
verify_dir "$BK/uploads" uploads "uploads/"
verify_dir "$BK/static"  static  "static/"

echo "============================================================"
if [ "$FAIL" = 0 ]; then echo "RESULT: MATCH — backup equals live ${ENV} (${SSH_DESC})."; exit 0
else echo "RESULT: DRIFT — backup differs from live ${ENV} (see above)."; exit 1; fi
