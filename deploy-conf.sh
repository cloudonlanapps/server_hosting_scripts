#!/bin/bash
set -e

# Usage: ./deploy-conf.sh <conf-file> <env>
#
# Wrapper around deploy.sh that reads secrets from the 'pass' password manager
# and per-environment settings from a host-specific conf file.
#
# Conf file (sourced as bash) must define:
#   PROJECT              Project name (passed to deploy.sh --project)
#   GIT_URL              Git repository URL
#   ENVS                 Bash array of allowed env names, e.g. ENVS=(prod beta dev)
#   <env>_GIT_BRANCH     Branch to deploy (required for non-dev envs; optional for dev)
#   <env>_PORT           Host port (required for non-dev envs; optional for dev, deploy.sh defaults to 8001)
#   <env>_ALLOWED_WEBSITES   CORS domains, comma-separated (required for non-dev envs; optional for dev, defaults to CORS=*)
#
# The env name "dev" is treated specially: --dev is passed to deploy.sh and
# all per-env settings become optional.
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

# A deployed environment must track a branch, never a commit. Pinning beta or
# prod to a SHA produces a stack nobody can move forward: the next promotion
# has nothing to fast-forward, and the deployed code stops corresponding to any
# branch a reader can inspect. Only dev may name a commit, for reproducing a
# specific build.
if [ "$ENV" != "dev" ] && printf '%s' "$GIT_BRANCH" | grep -qiE '^[0-9a-f]{7,40}$'; then
    echo "ERROR: ${GIT_BRANCH_VAR} looks like a commit SHA: $GIT_BRANCH"
    echo "       '$ENV' must track a branch (e.g. release, beta_release)."
    echo "       Only dev may be pinned to a commit."
    exit 1
fi

# In dev mode all per-env settings are optional (deploy.sh defaults port to
# 8001 and CORS to "*"). In server mode, branch / port / allowed_websites
# are all required.
if [ "$ENV" != "dev" ]; then
    for pair in "${GIT_BRANCH_VAR}:${GIT_BRANCH}" "${PORT_VAR}:${PORT}" "${ALLOWED_WEBSITES_VAR}:${ALLOWED_WEBSITES}"; do
        name="${pair%%:*}"
        val="${pair#*:}"
        if [ -z "$val" ]; then
            echo "ERROR: $CONF_FILE must define $name"
            exit 1
        fi
    done
fi

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

# Optional generic extra-env passthrough: the conf may define
#   <env>_EXTRA_ENV=( "NAME=literal" "NAME=@pass/key" ... )
# Values are exported into this process env (in memory, like the secrets above)
# and only the NAMES are forwarded to deploy.sh. This tooling stays
# domain-agnostic — it never inspects what these variables are for.
# shellcheck source=lib_extra_env.sh
source "$SCRIPT_DIR/lib_extra_env.sh"
resolve_extra_env "${ENV}_EXTRA_ENV"   # sets EXTRA_NAMES, exports the values

echo "==> Deploying ${PROJECT} [${ENV}] (branch: ${GIT_BRANCH:-repo default}, port: ${PORT:-default})"


# STACK_PREFIX (conf) names the stack after its environment instead of its git
# branch: <prefix>_<project>_<env>, e.g. p52_product_ihm_beta. Without it the
# scripts keep their historical <project>-<branch> naming, so an existing
# deployment is never renamed out from under itself.
STACK_NAME=""
[ -n "${STACK_PREFIX:-}" ] && STACK_NAME="${STACK_PREFIX}_${PROJECT}_${ENV}"

ARGS=(
    --project "$PROJECT"
    --git-url "$GIT_URL"
    --bootstrap-password "$BOOTSTRAP_PASSWORD"
    --postgres-password "$POSTGRES_PASSWORD"
    --secret-key "$SECRET_KEY"
    --github-token "$GITHUB_TOKEN"
)

# Split by origin: literals are forwarded as environment variables, values that
# came from `pass` are mounted as secret files. resolve_extra_env made the same
# distinction already, to validate the store.
[ ${#EXTRA_PLAIN_NAMES[@]} -gt 0 ] && ARGS+=(--extra-env-names "${EXTRA_PLAIN_NAMES[*]}")
[ ${#EXTRA_SECRET_NAMES[@]} -gt 0 ] && ARGS+=(--extra-secret-env-names "${EXTRA_SECRET_NAMES[*]}")
[ "$ENV" = "dev" ] && ARGS+=(--dev)
[ -n "$GIT_BRANCH" ] && ARGS+=(--git-branch "$GIT_BRANCH")
[ -n "$PORT" ] && ARGS+=(--port "$PORT")
[ -n "$ALLOWED_WEBSITES" ] && ARGS+=(--allowed-websites "$ALLOWED_WEBSITES")
[ -n "$STACK_NAME" ] && ARGS+=(--stack-name "$STACK_NAME")
[ -n "${STACK_PREFIX:-}" ] && ARGS+=(--db-container-name "${STACK_PREFIX}_${PROJECT}_postgres_${ENV}")
[ -n "${STACK_PREFIX:-}" ] && ARGS+=(--server-container-name "${STACK_PREFIX}_${PROJECT}_server_${ENV}")
[ -n "${PACKAGE:-}" ] && ARGS+=(--package-name "$PACKAGE")

exec "$SCRIPT_DIR/deploy.sh" "${ARGS[@]}"
