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
# admin commands run via `docker exec` over the container's trusted local
# socket.
#
# LOCAL vs REMOTE
#   Default: runs on THIS host. REMOTE=1: runs against a remote host over SSH
#   (SSH_USER/SSH_HOST/SSH_PORT from the conf; override REMOTE_SSH_{USER,HOST,
#   PORT}). The drop + the guarded wipe execute ON the target, so the path
#   guard and $HOME are evaluated on the same host that is modified.
#
# Knobs:  FORCE=1   skip the interactive "type the env to confirm" prompt
#
# DESTRUCTIVE and irreversible. Take a backup first if the data matters.

if [ $# -ne 2 ]; then echo "Usage: $0 <conf-file> <env>"; exit 1; fi
CONF_FILE="$1"; ENV="$2"

[ -f "$CONF_FILE" ] || { echo "ERROR: Conf file not found: $CONF_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$CONF_FILE"
[ -n "${PROJECT:-}" ] || { echo "ERROR: $CONF_FILE must define PROJECT"; exit 1; }
if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then echo "ERROR: $CONF_FILE must define ENVS=(...)"; exit 1; fi
ENV_OK=false; for e in "${ENVS[@]}"; do [ "$e" = "$ENV" ] && ENV_OK=true && break; done
[ "$ENV_OK" = true ] || { echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"; exit 1; }

GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"; GIT_BRANCH="${!GIT_BRANCH_VAR:-}"
if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"; exit 1; fi

# --- Target: local or remote over SSH ---
REMOTE_MODE=0; SSH_DESC="local"
if [ -n "${REMOTE:-}" ]; then
    REMOTE_MODE=1
    R_HOST="${REMOTE_SSH_HOST:-${SSH_HOST:-}}"
    R_USER="${REMOTE_SSH_USER:-${SSH_USER:-}}"
    R_PORT="${REMOTE_SSH_PORT:-${SSH_PORT:-22}}"
    [ -n "$R_HOST" ] || { echo "ERROR: REMOTE=1 but no SSH host (set SSH_HOST or REMOTE_SSH_HOST)."; exit 1; }
    SSH_TGT="${R_USER:+$R_USER@}$R_HOST"; SSH_DESC="$SSH_TGT (port $R_PORT)"
fi
runc() { if [ "$REMOTE_MODE" = 1 ]; then ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" "$1"; else bash -c "$1"; fi; }

if [ "$ENV" = "dev" ]; then
    COMPOSE_PROJECT_NAME="${PROJECT}-dev"; DATA_NAME="server_dev_${PROJECT}${GIT_BRANCH:+_$GIT_BRANCH}"
else
    COMPOSE_PROJECT_NAME="${PROJECT}-${GIT_BRANCH}"; DATA_NAME="server_${PROJECT}_${GIT_BRANCH}"
fi
# STACK_PREFIX (conf) names the stack after its environment rather than its
# branch — see deploy-conf.sh. Both naming schemes must resolve here, or reset
# would look for containers that do not exist.
if [ -n "${STACK_PREFIX:-}" ]; then
    STACK_NAME="${STACK_PREFIX}_${PROJECT}_${ENV}"
    COMPOSE_PROJECT_NAME="$STACK_NAME"
    DATA_NAME="$STACK_NAME"
    DB_CONTAINER="${STACK_PREFIX}_${PROJECT}_postgres_${ENV}"
    SERVER_CONTAINER="${STACK_PREFIX}_${PROJECT}_server_${ENV}"
else
    DB_CONTAINER="${COMPOSE_PROJECT_NAME}-postgres"
    SERVER_CONTAINER="${COMPOSE_PROJECT_NAME}-server"
fi
DATA_DIR="\$HOME/.local/share/${DATA_NAME}"   # literal $HOME — expands on target
UPLOAD_DIR="${DATA_DIR}/uploads"
STATIC_DIR="${DATA_DIR}/static"
POSTGRES_DB="$PROJECT"; POSTGRES_USER="$PROJECT"

# --- Preconditions ---
if [ "$REMOTE_MODE" = 1 ]; then
    ssh -p "$R_PORT" -o BatchMode=yes "$SSH_TGT" true 2>/dev/null \
        || { echo "ERROR: cannot SSH to $SSH_DESC."; exit 1; }
fi
runc "command -v docker >/dev/null" || { echo "ERROR: docker not found on $SSH_DESC."; exit 1; }
if ! runc "docker inspect -f '{{.State.Running}}' '$DB_CONTAINER' 2>/dev/null" | grep -q true; then
    echo "ERROR: postgres container '$DB_CONTAINER' is not running on $SSH_DESC."; exit 1
fi

# --- Confirm (destructive) ---
echo "============================================================"
echo " RESET (blank) ${ENV}  (project ${PROJECT})  on ${SSH_DESC}"
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
runc "docker stop '$SERVER_CONTAINER' >/dev/null 2>&1 || true"

# --- Drop + recreate an empty database (SQL via stdin to avoid quoting) ---
echo "==> Dropping and recreating empty database $POSTGRES_DB ..."
runc "docker exec -i '$DB_CONTAINER' psql -U '$POSTGRES_USER' -d postgres -v ON_ERROR_STOP=1 -tA" <<SQL
DROP DATABASE IF EXISTS "$POSTGRES_DB" WITH (FORCE);
CREATE DATABASE "$POSTGRES_DB" OWNER "$POSTGRES_USER";
SQL

# --- Clear the upload/static dirs (guard + delete run together ON the target) ---
clear_target_dir() {  # <dir-with-literal-$HOME>
    runc 'd="'"$1"'"; case "$d" in "$HOME/.local/share/"*) ;; *) echo "ERROR: refusing to wipe $d" >&2; exit 1;; esac; mkdir -p "$d"; find "$d" -mindepth 1 -delete'
}
echo "==> Clearing $UPLOAD_DIR ..."
clear_target_dir "$UPLOAD_DIR"
echo "==> Clearing $STATIC_DIR ..."
clear_target_dir "$STATIC_DIR"

echo "==> Reset complete: $ENV is blank on $SSH_DESC (server left stopped)."
echo "    Restore a backup:  restore-conf.sh $CONF_FILE $ENV <backup-dir>  (REMOTE=$REMOTE_MODE)"
