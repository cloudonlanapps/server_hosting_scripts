#!/bin/bash
set -e

# Usage: ./stop.sh --project NAME [options]
#
# Required:
#   --project NAME      Project name (e.g., myproduct)
#
# Environment modes:
#   --prod              Stop production containers
#   --dev               Stop development containers
#   --all               Stop all environments (beta, prod, dev)
#   (default)           Stop beta containers
#
# Stops containers cleanly without removing data volumes.

PROJECT_NAME=""
STOP_ENV="beta"  # Default to beta for safety

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: ./stop.sh --project NAME [options]"
            echo ""
            echo "Required:"
            echo "  --project NAME      Project name (e.g., myproduct)"
            echo ""
            echo "Environment modes:"
            echo "  --prod              Stop production containers"
            echo "  --dev               Stop development containers"
            echo "  --all               Stop all environments (beta, prod, dev)"
            echo "  (default)           Stop beta containers"
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
        --prod)
            STOP_ENV="prod"
            ;;
        --dev)
            STOP_ENV="dev"
            ;;
        --all)
            STOP_ENV="all"
            ;;
    esac
    shift
done

if [ -z "$PROJECT_NAME" ]; then
    echo "ERROR: --project is required (e.g., --project myproduct)"
    echo "Run ./stop.sh --help for usage."
    exit 1
fi

# Function to stop a specific environment
stop_environment() {
    local env_name="$1"
    local project_name="$2"

    echo "==> Stopping $env_name containers ($project_name)..."

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
    export COMPOSE_PROJECT_NAME="$project_name"
    export CORS_ALLOWED_ORIGINS=''
    export ENVIRONMENT='production'

    docker compose -p "$project_name" down 2>/dev/null || true
    echo "    $env_name stopped"
}

case $STOP_ENV in
    prod)
        stop_environment "PRODUCTION" "${PROJECT_NAME}-prod"
        ;;
    dev)
        stop_environment "DEVELOPMENT" "${PROJECT_NAME}-dev"
        ;;
    all)
        stop_environment "BETA" "${PROJECT_NAME}-beta"
        stop_environment "PRODUCTION" "${PROJECT_NAME}-prod"
        stop_environment "DEVELOPMENT" "${PROJECT_NAME}-dev"
        ;;
    beta|*)
        stop_environment "BETA" "${PROJECT_NAME}-beta"
        ;;
esac

echo ""
echo "==> Containers stopped"
echo ""
echo "Running containers:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "${PROJECT_NAME}-|NAMES" || echo "  (none)"
