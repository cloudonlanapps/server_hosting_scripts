#!/bin/bash
set -e

# Usage: ./deploy-env.sh <prod|beta>
# Reads secrets from 'pass' and calls deploy.sh with the correct configuration.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -z "$1" ] || { [ "$1" != "prod" ] && [ "$1" != "beta" ]; }; then
    echo "Usage: ./deploy-env.sh <prod|beta>"
    exit 1
fi

ENV="$1"

# Check pass is installed
if ! command -v pass &> /dev/null; then
    echo "ERROR: 'pass' (password manager) is not installed."
    echo "  macOS:  brew install pass gnupg pinentry-mac"
    echo "  Linux:  sudo apt install pass gnupg"
    echo "  See README.md for full setup instructions."
    exit 1
fi

# Define required pass keys
SHARED_KEYS=("club/github-token")
ENV_KEYS=("club/${ENV}/bootstrap-password" "club/${ENV}/postgres-password" "club/${ENV}/secret-key")
ALL_KEYS=("${SHARED_KEYS[@]}" "${ENV_KEYS[@]}")

# Check all keys exist before retrieving
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
GITHUB_TOKEN=$(pass show club/github-token)
BOOTSTRAP_PASSWORD=$(pass show "club/${ENV}/bootstrap-password")
POSTGRES_PASSWORD=$(pass show "club/${ENV}/postgres-password")
SECRET_KEY=$(pass show "club/${ENV}/secret-key")

# Environment-specific config
PROJECT="club"
GIT_URL="https://github.com/cloudonlanapps/club_server.git"

if [ "$ENV" = "prod" ]; then
    GIT_BRANCH="release"
    PORT="9000"
    ALLOWED_WEBSITES="p52icehockeyclub.in,www.p52icehockeyclub.in"
elif [ "$ENV" = "beta" ]; then
    GIT_BRANCH="main"
    PORT="9001"
    ALLOWED_WEBSITES="beta.p52icehockeyclub.in"
fi

echo "==> Deploying ${ENV} (branch: ${GIT_BRANCH}, port: ${PORT})"

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
