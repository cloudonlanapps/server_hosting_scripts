#!/bin/bash
set -e

# Usage: ./restart.sh --project NAME --bootstrap-password PASS --postgres-password PASS --secret-key KEY [options]
#
# Reads non-secret deployment config from $DATA_DIR/.deploy.env (saved by deploy.sh).
# Only secrets must be provided on the command line.
#
# Required:
#   --project NAME              Project name (used to find data directory and config)
#   --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)
#   --postgres-password PASS    Database password (must match existing database)
#   --secret-key KEY            JWT signing key (changing it invalidates existing user sessions)
#
# Environment modes (mutually exclusive):
#   --beta              Restart beta containers [default]
#   --prod              Restart production containers
#   --dev               Restart development containers

show_usage() {
    echo "Usage: ./restart.sh --project NAME --bootstrap-password PASS --postgres-password PASS --secret-key KEY [options]"
    echo ""
    echo "Reads deployment config (port, data-dir, allowed-websites, etc.) from"
    echo "the .deploy.env file saved by deploy.sh. Only secrets are needed here."
    echo ""
    echo "Required:"
    echo "  --project NAME              Project name (used to find data directory and config)"
    echo "  --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)"
    echo "  --postgres-password PASS    Database password (must match existing database)"
    echo "  --secret-key KEY            JWT signing key (changing it invalidates existing user sessions)"
    echo ""
    echo "Environment modes (mutually exclusive):"
    echo "  --beta              Restart beta containers [default]"
    echo "  --prod              Restart production containers"
    echo "  --dev               Restart development containers"
    echo ""
    echo "Examples:"
    echo "  ./restart.sh --project myproduct --bootstrap-password pass123 --postgres-password dbpass123 --secret-key KEY --beta"
    echo "  ./restart.sh --project myproduct --bootstrap-password pass123 --postgres-password dbpass123 --secret-key KEY --prod"
    echo "  ./restart.sh --project myproduct --bootstrap-password pass123 --postgres-password dbpass123 --secret-key KEY --dev"
}

PROJECT_NAME=""
BOOTSTRAP_PASSWORD=""
POSTGRES_PASSWORD=""
SECRET_KEY=""
DEPLOY_ENV="beta"  # Default to beta for safety

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            show_usage
            exit 0
            ;;
        --project)
            shift
            PROJECT_NAME="$1"
            ;;
        --project=*)
            PROJECT_NAME="${1#*=}"
            ;;
        --bootstrap-password)
            shift
            BOOTSTRAP_PASSWORD="$1"
            ;;
        --bootstrap-password=*)
            BOOTSTRAP_PASSWORD="${1#*=}"
            ;;
        --postgres-password)
            shift
            POSTGRES_PASSWORD="$1"
            ;;
        --postgres-password=*)
            POSTGRES_PASSWORD="${1#*=}"
            ;;
        --secret-key)
            shift
            SECRET_KEY="$1"
            ;;
        --secret-key=*)
            SECRET_KEY="${1#*=}"
            ;;
        --beta)
            DEPLOY_ENV="beta"
            ;;
        --prod)
            DEPLOY_ENV="prod"
            ;;
        --dev)
            DEPLOY_ENV="dev"
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
    shift
done

# Validate required arguments
if [ -z "$PROJECT_NAME" ] || [ -z "$BOOTSTRAP_PASSWORD" ] || [ -z "$POSTGRES_PASSWORD" ] || [ -z "$SECRET_KEY" ]; then
    echo "ERROR: --project, --bootstrap-password, --postgres-password, and --secret-key are required"
    show_usage
    exit 1
fi

# Determine default data directory to find config file
case $DEPLOY_ENV in
    prod)   DEFAULT_DATA_DIR="/var/lib/${PROJECT_NAME}-server" ;;
    dev)    DEFAULT_DATA_DIR="./data-${PROJECT_NAME}" ;;
    beta|*) DEFAULT_DATA_DIR="/var/lib/${PROJECT_NAME}-server-beta" ;;
esac

# Load deployment config saved by deploy.sh
DEPLOY_CONFIG="$DEFAULT_DATA_DIR/.deploy.env"
if [ ! -f "$DEPLOY_CONFIG" ]; then
    echo "ERROR: Deployment config not found: $DEPLOY_CONFIG"
    echo "Run deploy.sh first to create the initial deployment."
    exit 1
fi

echo "==> Loading deployment config from $DEPLOY_CONFIG..."
source "$DEPLOY_CONFIG"

# Build CORS origins from saved ALLOWED_WEBSITES
if [ "$DEPLOY_ENV" = "dev" ]; then
    CORS_ALLOWED_ORIGINS="*"
else
    CORS_ALLOWED_ORIGINS=$(echo "$ALLOWED_WEBSITES" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's|^|https://|' | tr '\n' ',' | sed 's/,$//')
fi

echo "==> Restarting $(echo "$DEPLOY_ENV" | tr '[:lower:]' '[:upper:]') environment"

# Determine port binding
if [ "$DEPLOY_ENV" = "dev" ]; then
    SERVER_PORT="${PORT}:8000"
else
    SERVER_PORT="127.0.0.1:${PORT}:8000"
fi

# Export environment variables for docker-compose
export PROJECT_NAME
export GIT_URL
export POSTGRES_PASSWORD
export POSTGRES_USER="$PROJECT_NAME"
export POSTGRES_DB="$PROJECT_NAME"
export SECRET_KEY
export BOOTSTRAP_PASSWORD
export DATA_DIR
export SERVER_PORT
export COMPOSE_PROJECT_NAME
export CORS_ALLOWED_ORIGINS
export ENVIRONMENT

echo "==> Environment: $DEPLOY_ENV"
echo "    Port: $PORT"
echo "    Data directory: $DATA_DIR"
echo "    Project name: $COMPOSE_PROJECT_NAME"

echo "==> Restarting containers..."
docker compose -p "$COMPOSE_PROJECT_NAME" up -d

# Function to wait for containers to become healthy
wait_for_healthy() {
    local timeout=${1:-90}
    local interval=${2:-3}
    local start_time=$(date +%s)
    local elapsed=0

    local db_container="${COMPOSE_PROJECT_NAME}-postgres"
    local server_container="${COMPOSE_PROJECT_NAME}-server"

    echo "==> Waiting for services to become healthy (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        local db_health=$(docker inspect --format='{{.State.Health.Status}}' "$db_container" 2>/dev/null || echo "unknown")
        local server_health=$(docker inspect --format='{{.State.Health.Status}}' "$server_container" 2>/dev/null || echo "unknown")
        local server_running=$(docker inspect --format='{{.State.Running}}' "$server_container" 2>/dev/null || echo "false")

        if [ "$server_running" = "false" ]; then
            echo ""
            echo "ERROR: Server container is not running"
            docker compose -p "$COMPOSE_PROJECT_NAME" logs --tail=20 server
            return 1
        fi

        if [ "$server_health" = "unhealthy" ]; then
            echo ""
            echo "ERROR: Server container is unhealthy"
            docker compose -p "$COMPOSE_PROJECT_NAME" logs --tail=20 server
            return 1
        fi

        printf "\r  [%3ds] db: %-10s | server: %-10s" "$elapsed" "$db_health" "$server_health"

        if [ "$db_health" = "healthy" ] && [ "$server_health" = "healthy" ]; then
            local end_time=$(date +%s)
            local total_time=$((end_time - start_time))
            echo ""
            echo "==> All services healthy! (took ${total_time}s)"
            return 0
        fi

        sleep $interval
        elapsed=$(( $(date +%s) - start_time ))
    done

    echo ""
    echo "ERROR: Timeout waiting for services to become healthy"
    echo "Current status:"
    docker compose -p "$COMPOSE_PROJECT_NAME" ps
    echo ""
    echo "Server logs:"
    docker compose -p "$COMPOSE_PROJECT_NAME" logs --tail=50 server
    return 1
}

# Wait for containers to become healthy
if ! wait_for_healthy 90 3; then
    exit 1
fi

echo ""
echo "Services:"
docker compose -p "$COMPOSE_PROJECT_NAME" ps
