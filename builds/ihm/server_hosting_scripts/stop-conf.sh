#!/bin/bash
set -e

# Usage: ./stop-conf.sh <conf-file> <env>
#
# Wrapper around stop.sh. Reads PROJECT and per-env branch from the host
# conf file. Does NOT need 'pass' — stop.sh requires no secrets.

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


# STACK_PREFIX (conf) names the stack after its environment instead of its git
# branch: <prefix>_<project>_<env>, e.g. p52_product_ihm_beta. Without it the
# scripts keep their historical <project>-<branch> naming, so an existing
# deployment is never renamed out from under itself.
STACK_NAME=""
[ -n "${STACK_PREFIX:-}" ] && STACK_NAME="${STACK_PREFIX}_${PROJECT}_${ENV}"

ARGS=(--project "$PROJECT")
[ "$ENV" = "dev" ] && ARGS+=(--dev)
[ -n "$GIT_BRANCH" ] && ARGS+=(--git-branch "$GIT_BRANCH")
[ -n "$STACK_NAME" ] && ARGS+=(--stack-name "$STACK_NAME")
[ -n "${STACK_PREFIX:-}" ] && ARGS+=(--db-container-name "${STACK_PREFIX}_${PROJECT}_postgres_${ENV}")
[ -n "${STACK_PREFIX:-}" ] && ARGS+=(--server-container-name "${STACK_PREFIX}_${PROJECT}_server_${ENV}")

exec "$SCRIPT_DIR/stop.sh" "${ARGS[@]}"
