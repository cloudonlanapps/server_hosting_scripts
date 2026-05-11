#!/bin/bash
set -e

# Usage: ./deploy-with-pass.sh <conf-file> <env>
#
# Wrapper around deploy.sh that reads secrets from the 'pass' password manager
# and per-environment settings from a host-specific conf file.
#
# Conf file (sourced as bash) must define:
#   PROJECT              Project name (passed to deploy.sh --project)
#   GIT_URL              Git repository URL
#   ENVS                 Bash array of allowed env names, e.g. ENVS=(prod beta)
#   <env>_GIT_BRANCH     Branch to deploy for each env in ENVS
#   <env>_PORT           Host port for each env
#   <env>_ALLOWED_WEBSITES   Comma-separated CORS domains for each env
#
# Optional:
#   PASS_PREFIX          Pass key prefix (default: $PROJECT)
#
# Required pass entries (with prefix=$PASS_PREFIX):
#   <prefix>/github-token
#   <prefix>/<env>/bootstrap-password
#   <prefix>/<env>/postgres-password
#   <prefix>/<env>/secret-key

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

# Validate conf
for var in PROJECT GIT_URL; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $CONF_FILE must define $var"
        exit 1
    fi
done

if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then
    echo "ERROR: $CONF_FILE must define ENVS=(...) with at least one entry"
    exit 1
fi

# Check ENV is allowed
ENV_OK=false
for e in "${ENVS[@]}"; do
    [ "$e" = "$ENV" ] && ENV_OK=true && break
done
if [ "$ENV_OK" = false ]; then
    echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"
    exit 1
fi

# Resolve per-env settings via indirect expansion
GIT_BRANCH_VAR="${ENV}_GIT_BRANCH"
PORT_VAR="${ENV}_PORT"
ALLOWED_WEBSITES_VAR="${ENV}_ALLOWED_WEBSITES"

GIT_BRANCH="${!GIT_BRANCH_VAR}"
PORT="${!PORT_VAR}"
ALLOWED_WEBSITES="${!ALLOWED_WEBSITES_VAR}"

for pair in "${GIT_BRANCH_VAR}:${GIT_BRANCH}" "${PORT_VAR}:${PORT}" "${ALLOWED_WEBSITES_VAR}:${ALLOWED_WEBSITES}"; do
    name="${pair%%:*}"
    val="${pair#*:}"
    if [ -z "$val" ]; then
        echo "ERROR: $CONF_FILE must define $name"
        exit 1
    fi
done

PASS_PREFIX="${PASS_PREFIX:-$PROJECT}"

# Check pass is installed
if ! command -v pass &> /dev/null; then
    echo "ERROR: 'pass' (password manager) is not installed."
    echo "  macOS:  brew install pass gnupg pinentry-mac"
    echo "  Linux:  sudo apt install pass gnupg"
    exit 1
fi

# Required pass keys
SHARED_KEYS=("${PASS_PREFIX}/github-token")
ENV_KEYS=(
    "${PASS_PREFIX}/${ENV}/bootstrap-password"
    "${PASS_PREFIX}/${ENV}/postgres-password"
    "${PASS_PREFIX}/${ENV}/secret-key"
)
ALL_KEYS=("${SHARED_KEYS[@]}" "${ENV_KEYS[@]}")

# Pre-check all keys exist
MISSING=()
for key in "${ALL_KEYS[@]}"; do
    if ! pass show "$key" &> /dev/null; then
        MISSING+=("$key")
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "ERROR: Missing secrets in pass store:"
    for key in "${MISSING[@]}"; do
        echo "  - $key"
    done
    echo ""
    echo "Add them with:"
    for key in "${MISSING[@]}"; do
        echo "  pass insert $key"
    done
    exit 1
fi

# Retrieve secrets
GITHUB_TOKEN=$(pass show "${PASS_PREFIX}/github-token")
BOOTSTRAP_PASSWORD=$(pass show "${PASS_PREFIX}/${ENV}/bootstrap-password")
POSTGRES_PASSWORD=$(pass show "${PASS_PREFIX}/${ENV}/postgres-password")
SECRET_KEY=$(pass show "${PASS_PREFIX}/${ENV}/secret-key")

echo "==> Deploying ${PROJECT} [${ENV}] (branch: ${GIT_BRANCH}, port: ${PORT})"

exec "$SCRIPT_DIR/deploy.sh" \
    --project "$PROJECT" \
    --git-url "$GIT_URL" \
    --git-branch "$GIT_BRANCH" \
    --port "$PORT" \
    --bootstrap-password "$BOOTSTRAP_PASSWORD" \
    --postgres-password "$POSTGRES_PASSWORD" \
    --secret-key "$SECRET_KEY" \
    --github-token "$GITHUB_TOKEN" \
    --allowed-websites "$ALLOWED_WEBSITES"
