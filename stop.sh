#!/bin/bash
set -e

# Usage: ./stop.sh --project NAME [options]
#
# Required:
#   --project NAME          Project name (e.g., myproduct)
#
# Options:
#   --git-branch BRANCH     Git branch (required in server mode, not used in dev mode)
#   --dev                   Stop development containers
#
# Stops containers cleanly without removing data volumes.

PROJECT_NAME=""
DEV_MODE=false
GIT_BRANCH=""

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: ./stop.sh --project NAME [options]"
            echo ""
            echo "Required:"
            echo "  --project NAME          Project name (e.g., myproduct)"
            echo ""
            echo "Options:"
            echo "  --git-branch BRANCH     Git branch (required in server mode, not used in dev mode)"
            echo "  --dev                   Stop development containers"
            echo ""
            echo "Examples:"
            echo "  ./stop.sh --project myproduct                          # stops main (default)"
            echo "  ./stop.sh --project myproduct --git-branch release     # stops release"
            echo "  ./stop.sh --project myproduct --dev                    # stops dev"
            echo ""
            echo "Stops containers cleanly without removing data volumes."
            exit 0
            ;;
        --project)
            shift
            PROJECT_NAME="$1"
            ;;
        --project=*)
            PROJECT_NAME="${1#*=}"
            ;;
        --dev)
            DEV_MODE=true
            ;;
        --git-branch)
            shift
            GIT_BRANCH="$1"
            ;;
        --git-branch=*)
            GIT_BRANCH="${1#*=}"
            ;;
    esac
    shift
done

if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: --project is required (e.g., --project myproduct)"
    echo "Run ./stop.sh --help for usage."
    exit 1
fi

# Server mode requires --git-branch
if [ "$DEV_MODE" = false ] && [ -z "$GIT_BRANCH" ]; then
    echo "ERROR: --git-branch is required in server mode (e.g., --git-branch main, --git-branch release)"
    echo "  Use --dev for development mode"
    exit 1
fi

# Determine compose project name
if [ "$DEV_MODE" = true ]; then
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}-dev"
else
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}-${GIT_BRANCH}"
fi

echo "==> Stopping containers ($COMPOSE_PROJECT_NAME)..."

# Set placeholder values for environment variables referenced in docker-compose.yml
# These are not used during 'down' but are required to parse the compose file
export PROJECT_NAME='placeholder'
export GIT_URL='placeholder'
export POSTGRES_DB='placeholder'
export POSTGRES_USER='placeholder'
export POSTGRES_PASSWORD='placeholder'
export SECRET_KEY='placeholder'
export BOOTSTRAP_PASSWORD='placeholder'
export DATA_DIR='/tmp'
export SERVER_PORT='8000:8000'
export COMPOSE_PROJECT_NAME
export CORS_ALLOWED_ORIGINS=''
export ENVIRONMENT='production'

docker compose -p "$COMPOSE_PROJECT_NAME" down 2>/dev/null || true

echo "==> Containers stopped"
echo ""
echo "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "${PROJECT_NAME}-|NAMES" || echo "  (none)"
