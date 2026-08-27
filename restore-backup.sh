#!/bin/bash
#
# restore-backup.sh — restore a deployed environment from an archive that is
# already on this host.
#
# Usage:
#   ./restore-backup.sh <conf-file> --list
#   ./restore-backup.sh <conf-file> <env>                      # newest archive
#   ./restore-backup.sh <conf-file> <env> 20260820-113638      # a dated one
#   ./restore-backup.sh <conf-file> <env> /path/to/dump.tar.gz # anywhere
#   DRY_RUN=1 ./restore-backup.sh <conf-file> <env>
#
# Options:
#   --backup-dir DIR  where archives live (default: ./backup beside the conf)
#   --files DIR       tree containing static/ and uploads/
#   --no-files        restore the database only — see the warning below
#
# SCOPE: this reads a LOCAL directory and nothing else. It does not know where
# backups are produced or stored, and never reaches a backup host. Getting an
# archive onto this machine is a separate job — deliberately, so that restore
# needs no credentials for, or network path to, wherever backups live.
#
# It expects what an external backup job leaves behind:
#   <backup-dir>/<project>-<stamp>.tar.gz   the database archive
#   <backup-dir>/files/static/              page content, images, video
#   <backup-dir>/files/uploads/             member uploads
#
# RESTORE ALL THREE unless you mean otherwise. A database-only restore leaves
# the app broken in a way that reads as a code fault: page content is served
# from static/, so an empty static/ makes those fetches 404 and the SDK casts
# the error body to a Map<String, dynamic> and throws a type error.
#
# ENCRYPTED MEDIA: uploads/ is ciphertext under the *source* environment's KEK.
# Restoring prod's files into beta only works if beta's ENCRYPTION_KEY is
# prod's — copy it in `pass` first, or the restored media will not decrypt.
#
# SCHEMA GUARD: the archive's alembic revision is read out of the dump itself
# and compared against the revision the target is running. A mismatch means the
# code has moved on from the data (or vice versa); restoring anyway corrupts
# silently, so it refuses. Override with ALLOW_SCHEMA_MISMATCH=1 only if you
# intend to migrate immediately afterwards.

set -euo pipefail

CONF_FILE="${1:-}"
if [ -z "$CONF_FILE" ] || [ ! -f "$CONF_FILE" ]; then
    echo "Usage: $(basename "$0") <conf-file> {<env>|--list} [archive] [options]" >&2
    exit 2
fi
shift

# shellcheck disable=SC1090
source "$CONF_FILE"
: "${PROJECT:?PROJECT missing from $CONF_FILE}"

CONF_DIR="$(cd "$(dirname "$CONF_FILE")" && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$CONF_DIR/backup}"
WORK="$CONF_DIR/.restore-work"

ARCHIVE_SEL=""
FILES_DIR=""
WITH_FILES=1
DO_LIST=0

ENV_ARG="${1:-}"; shift || true
[ "$ENV_ARG" = "--list" ] && { DO_LIST=1; ENV_ARG="list"; }
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then ARCHIVE_SEL="$1"; shift; fi

while [ $# -gt 0 ]; do
    case "$1" in
        --backup-dir)    shift; BACKUP_DIR="$1" ;;
        --backup-dir=*)  BACKUP_DIR="${1#*=}" ;;
        --files)         shift; FILES_DIR="$1" ;;
        --files=*)       FILES_DIR="${1#*=}" ;;
        --no-files)      WITH_FILES=0 ;;
        --list)          DO_LIST=1 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

list_archives() {
    echo "Archives in $BACKUP_DIR:"
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "  (no such directory)"
        echo
        echo "Create it, or point elsewhere with --backup-dir /srv/backups."
        return 1
    fi
    local found=0 f
    while read -r f; do
        [ -z "$f" ] && continue
        found=1
        printf '  %-34s %8s  %s\n' "$(basename "$f")" \
            "$(du -h "$f" | cut -f1)" \
            "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
    done < <(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null)
    if [ "$found" != "1" ]; then
        echo "  (none)"
        echo
        echo "Copy a backup onto this host first — nothing here fetches it."
        echo "Expected:"
        echo "  ${PROJECT}-<stamp>.tar.gz   database archive"
        echo "  files/static/               page content, images, video"
        echo "  files/uploads/              member uploads"
        return 1
    fi
    echo
    if [ -d "$BACKUP_DIR/files/static" ]; then
        echo "File tree: $BACKUP_DIR/files (present)"
    else
        echo "File tree: MISSING — restore will need --files or --no-files"
    fi
}

if [ "$DO_LIST" = "1" ]; then list_archives; exit $?; fi

case " ${ENVS[*]:-prod beta dev} " in
    *" $ENV_ARG "*) ;;
    *) echo "Usage: $(basename "$0") <conf-file> {${ENVS[*]:-prod|beta|dev}} [archive] [options]" >&2
       echo "       $(basename "$0") <conf-file> --list" >&2
       echo "" >&2
       echo "  archive       timestamp, filename, or full path." >&2
       echo "                Omitted, the newest in the backup directory is used." >&2
       echo "  --files DIR   tree containing static/ and uploads/" >&2
       echo "  --no-files    restore the database only (see the header)" >&2
       echo "" >&2
       echo "  Archives are read from: $BACKUP_DIR" >&2
       exit 2 ;;
esac

# ── Derive container / data-dir names exactly like deploy-conf.sh ───────────
BRANCH_VAR="${ENV_ARG}_GIT_BRANCH"; GIT_BRANCH="${!BRANCH_VAR:-}"
if [ "$ENV_ARG" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"
    DATA_NAME="server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"
    DATA_NAME="server_${PROJECT}_${GIT_BRANCH}"
fi
# STACK_PREFIX (conf) names the stack after its environment rather than its
# branch. Both schemes must resolve here, or restore would look for containers
# that do not exist. Note that backup-conf.sh / restore-conf.sh / verify-conf.sh
# implement only the branch scheme, which is why they are not wired into the
# justfile — see the README.
if [ -n "${STACK_PREFIX:-}" ]; then
    DATA_NAME="${STACK_PREFIX}_${PROJECT}_${ENV_ARG}"
    PG="${STACK_PREFIX}_${PROJECT}_postgres_${ENV_ARG}"
    SRV="${STACK_PREFIX}_${PROJECT}_server_${ENV_ARG}"
else
    PG="${COMPOSE_PROJECT_NAME}-postgres"
    SRV="${COMPOSE_PROJECT_NAME}-server"
fi
DATA_DIR="$HOME/.local/share/${DATA_NAME}"
POSTGRES_DB="$PROJECT"
POSTGRES_USER="$PROJECT"

# ── Resolve the archive ─────────────────────────────────────────────────────
if [ -n "$ARCHIVE_SEL" ]; then
    if   [ -f "$ARCHIVE_SEL" ];                                  then DUMP_SRC="$ARCHIVE_SEL"
    elif [ -f "$BACKUP_DIR/$ARCHIVE_SEL" ];                      then DUMP_SRC="$BACKUP_DIR/$ARCHIVE_SEL"
    elif [ -f "$BACKUP_DIR/${PROJECT}-$ARCHIVE_SEL.tar.gz" ];    then DUMP_SRC="$BACKUP_DIR/${PROJECT}-$ARCHIVE_SEL.tar.gz"
    else
        echo "ERROR: no archive matching '$ARCHIVE_SEL'." >&2
        echo "       Tried it as a path, and under $BACKUP_DIR." >&2
        echo "" >&2
        list_archives >&2 || true
        exit 1
    fi
else
    DUMP_SRC=$(ls -1t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1 || true)
    if [ -z "$DUMP_SRC" ]; then
        echo "ERROR: no archive in $BACKUP_DIR" >&2
        echo "       Copy a backup onto this host first — that is not this script's job." >&2
        exit 1
    fi
    echo "==> No archive given; using the newest: $(basename "$DUMP_SRC")"
fi

[ -z "$FILES_DIR" ] && FILES_DIR="$(dirname "$DUMP_SRC")/files"
if [ "$WITH_FILES" = "1" ] && [ ! -d "$FILES_DIR/static" ]; then
    echo "ERROR: no static/ under $FILES_DIR" >&2
    echo "       Point --files at the tree containing static/ and uploads/," >&2
    echo "       or pass --no-files to restore the database alone." >&2
    exit 1
fi

PG_RUNNING=0
docker inspect -f '{{.State.Running}}' "$PG" 2>/dev/null | grep -q true && PG_RUNNING=1

# A dry run reports the container state rather than refusing on it, so the
# resolved names can be checked from any machine — including before the stack
# has ever been deployed, which is when a naming mistake is cheapest to catch.
if [ "$PG_RUNNING" != "1" ] && [ "${DRY_RUN:-0}" != "1" ]; then
    echo "ERROR: $PG is not running — deploy $ENV_ARG before restoring into it." >&2
    exit 1
fi

if [ "${DRY_RUN:-0}" = "1" ]; then
    echo "conf      : $CONF_FILE"
    echo "project   : $PROJECT"
    echo "env       : $ENV_ARG"
    echo "archive   : $DUMP_SRC"
    if [ "$WITH_FILES" = 1 ]; then
        echo "files     : $FILES_DIR/static"
        echo "            $FILES_DIR/uploads"
    else
        echo "files     : (skipped: --no-files)"
    fi
    echo "data dir  : $DATA_DIR"
    echo "database  : $POSTGRES_DB (owner $POSTGRES_USER)"
    echo "containers: $SRV / $PG"
    echo "            $([ "$PG_RUNNING" = 1 ] && echo "postgres is running" || echo "postgres NOT running — deploy $ENV_ARG before a real run")"
    echo "staging   : $WORK  (removed on exit)"
    exit 0
fi

mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "==> [1/4] Unpacking $(basename "$DUMP_SRC")"
gzip -dc "$DUMP_SRC" > "$WORK/dump.tar"

echo "==> [2/4] Checking schema revision"
# The revision travels inside the dump, so this works on any archive the
# operator hands us — no sidecar manifest, no contact with the backup host.
#
# Read it with the container's pg_restore, not the host's: the host is not
# required to have PostgreSQL client tools installed, and the version that
# matters is the one that will perform the restore.
docker cp "$WORK/dump.tar" "$PG":/tmp/revcheck.tar >/dev/null
ARCHIVE_REV="$(docker exec "$PG" pg_restore --data-only -t alembic_version -f - /tmp/revcheck.tar 2>/dev/null \
    | grep -Eo '^[0-9a-z]{8,}$' | head -1 || true)"
docker exec "$PG" rm -f /tmp/revcheck.tar
TARGET_REV="$(docker exec "$PG" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
    'select version_num from alembic_version' 2>/dev/null | tr -d '[:space:]' || true)"
if [ -z "$ARCHIVE_REV" ]; then
    echo "    archive revision: unreadable — skipping the check"
elif [ -z "$TARGET_REV" ]; then
    echo "    target revision: none (empty database) — nothing to compare"
elif [ "$ARCHIVE_REV" != "$TARGET_REV" ]; then
    echo "ERROR: schema mismatch." >&2
    echo "       archive: $ARCHIVE_REV" >&2
    echo "       target : $TARGET_REV" >&2
    echo "       Restoring across a migration boundary corrupts silently." >&2
    echo "       Deploy the matching code first, or set ALLOW_SCHEMA_MISMATCH=1" >&2
    echo "       if you intend to migrate straight afterwards." >&2
    [ "${ALLOW_SCHEMA_MISMATCH:-0}" = "1" ] || exit 1
    echo "    ALLOW_SCHEMA_MISMATCH=1 — continuing anyway." >&2
else
    echo "    revision $ARCHIVE_REV matches the target"
fi

if [ "$WITH_FILES" = "1" ]; then
    echo "==> [3/4] Syncing static/ and uploads/ from $FILES_DIR"
    for sub in static uploads; do
        [ -d "$FILES_DIR/$sub" ] || { echo "    $sub: absent, skipped"; continue; }
        mkdir -p "$DATA_DIR/$sub"
        rsync -a "$FILES_DIR/$sub/" "$DATA_DIR/$sub/"
        echo "    $sub synced"
    done
else
    echo "==> [3/4] Skipping static/ and uploads/ (--no-files)"
fi

echo "==> [4/4] Restoring the database"
docker cp "$WORK/dump.tar" "$PG":/tmp/dump.tar
docker stop "$SRV" >/dev/null
# Drop and recreate so the bootstrap rows created at deploy cannot collide with
# the dump's own rows — a data-only restore into a bootstrapped database fails
# on duplicate keys and foreign keys.
docker exec "$PG" psql -U "$POSTGRES_USER" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$POSTGRES_DB' AND pid<>pg_backend_pid();" >/dev/null
docker exec "$PG" psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE $POSTGRES_DB;" >/dev/null
docker exec "$PG" psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER;" >/dev/null
docker exec "$PG" pg_restore --no-owner --no-acl -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/dump.tar 2>&1 | tail -3 || true
docker exec "$PG" rm -f /tmp/dump.tar
docker start "$SRV" >/dev/null

sleep 12
echo "==> Restored:"
echo "    tables=$(docker exec "$PG" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc 'select count(*) from pg_stat_user_tables')"
echo "    rows=$(docker exec "$PG" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc 'select coalesce(sum(n_live_tup),0) from pg_stat_user_tables')"
docker ps --format "    {{.Names}}|{{.Status}}" | grep -E "${PG}|${SRV}" || true
echo "==> Done. Staging removed."
