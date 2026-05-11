#!/bin/bash
set -e

# Usage: ./restart-with-pass.sh <conf-file> <env>
#
# Wrapper around restart.sh. Reads secrets from 'pass' and the project name
# / env mapping from a host conf file (same format as deploy-with-pass.sh).
# restart.sh itself reuses the saved .deploy.env, so branch is the only
# per-env setting needed here (and only in non-dev mode).
#
# Conf must define PROJECT and ENVS=(...). For each non-dev env, also define
# <env>_GIT_BRANCH. PASS_PREFIX defaults to $PROJECT.

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

if [ -z "$PROJECT" ]; then
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
GIT_BRANCH="${!GIT_BRANCH_VAR}"

if [ "$ENV" != "dev" ] && [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: $CONF_FILE must define $GIT_BRANCH_VAR"
    exit 1
fi

PASS_PREFIX="${PASS_PREFIX:-$PROJECT}"

if ! command -v pass &> /dev/null; then
    echo "ERROR: 'pass' (password manager) is not installed."
    exit 1
fi

KEYS=(
    "${PASS_PREFIX}/${ENV}/bootstrap-password"
    "${PASS_PREFIX}/${ENV}/postgres-password"
    "${PASS_PREFIX}/${ENV}/secret-key"
)

MISSING=()
for key in "${KEYS[@]}"; do
    if ! pass show "$key" &> /dev/null; then
        MISSING+=("$key")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing secrets in pass store:"
    for key in "${MISSING[@]}"; do
        echo "  - $key"
    done
    exit 1
fi

BOOTSTRAP_PASSWORD=$(pass show "${PASS_PREFIX}/${ENV}/bootstrap-password")
POSTGRES_PASSWORD=$(pass show "${PASS_PREFIX}/${ENV}/postgres-password")
SECRET_KEY=$(pass show "${PASS_PREFIX}/${ENV}/secret-key")

echo "==> Restarting ${PROJECT} [${ENV}]"

ARGS=(
    --project "$PROJECT"
    --bootstrap-password "$BOOTSTRAP_PASSWORD"
    --postgres-password "$POSTGRES_PASSWORD"
    --secret-key "$SECRET_KEY"
)

[ "$ENV" = "dev" ] && ARGS+=(--dev)
[ -n "$GIT_BRANCH" ] && ARGS+=(--git-branch "$GIT_BRANCH")

exec "$SCRIPT_DIR/restart.sh" "${ARGS[@]}"
