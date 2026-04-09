#!/bin/bash
set -e

# Usage: ./deploy.sh --bootstrap-password PASS --postgres-password PASS [options]
#
# Required:
#   --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)
#   --postgres-password PASS    Database password (fixed once created, change only with --reset)
#
# Environment modes (mutually exclusive):
#   --beta              Beta environment (port 8001, /var/lib/club-server-beta) [default]
#   --prod              Deploy to production (port 8000, /var/lib/club-server)
#   --dev               Development mode for macOS (port 8000, ./data, all CORS, port exposed)
#
# Options:
#   --reset             Drop all tables before starting (fresh database)
#   --secret-key KEY    JWT signing key (auto-generated if not provided; changing it invalidates existing user sessions)
#   --github-token TOK  GitHub token for cloning private repo
#   --data-dir DIR      Custom data directory (default: depends on environment)
#   --port PORT         Custom port (default: depends on environment)
#   --allowed-websites SITES  Domain(s) for CORS, comma-separated (required for --prod and --beta)

show_usage() {
    echo "Usage: ./deploy.sh --bootstrap-password PASS --postgres-password PASS [options]"
    echo ""
    echo "Required:"
    echo "  --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)"
    echo "  --postgres-password PASS    Database password (fixed once created, change only with --reset)"
    echo ""
    echo "Environment modes (mutually exclusive):"
    echo "  --beta              Beta environment (port 8001, /var/lib/club-server-beta) [default]"
    echo "  --prod              Deploy to production (port 8000, /var/lib/club-server)"
    echo "  --dev               Development mode for macOS (port 8000, ./data, all CORS, port exposed)"
    echo ""
    echo "Options:"
    echo "  --reset             Drop all tables before starting (fresh database)"
    echo "  --secret-key KEY    JWT signing key (auto-generated if not provided; changing it invalidates existing user sessions)"
    echo "  --github-token TOK  GitHub token for cloning private repo"
    echo "  --data-dir DIR      Custom data directory (default: /var/lib/club-server-beta, /var/lib/club-server, or ./data)"
    echo "  --port PORT         Custom port (default: 8001 for beta, 8000 for prod/dev)"
    echo "  --allowed-websites SITES  Domain(s) for CORS, comma-separated (required for --prod and --beta)"
    echo ""
    echo "Examples:"
    echo "  ./deploy.sh --bootstrap-password pass123 --postgres-password dbpass123 --allowed-websites beta.example.com"
    echo "  ./deploy.sh --bootstrap-password pass123 --postgres-password dbpass123 --allowed-websites www.example.com,example.com --prod"
    echo "  ./deploy.sh --bootstrap-password pass123 --postgres-password dbpass123 --dev"
}

BOOTSTRAP_PASSWORD=""
POSTGRES_PASSWORD=""
SECRET_KEY=""
GITHUB_TOKEN=""
RESET_DB=false
DEPLOY_ENV="beta"  # Default to beta for safety
CUSTOM_DATA_DIR=""
CUSTOM_PORT=""
ALLOWED_WEBSITES=""

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            show_usage
            exit 0
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
        --reset)
            RESET_DB=true
            ;;
        --secret-key)
            shift
            SECRET_KEY="$1"
            ;;
        --secret-key=*)
            SECRET_KEY="${1#*=}"
            ;;
        --github-token)
            shift
            GITHUB_TOKEN="$1"
            ;;
        --github-token=*)
            GITHUB_TOKEN="${1#*=}"
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
        --data-dir)
            shift
            CUSTOM_DATA_DIR="$1"
            ;;
        --data-dir=*)
            CUSTOM_DATA_DIR="${1#*=}"
            ;;
        --port)
            shift
            CUSTOM_PORT="$1"
            ;;
        --port=*)
            CUSTOM_PORT="${1#*=}"
            ;;
        --allowed-websites)
            shift
            ALLOWED_WEBSITES="$1"
            ;;
        --allowed-websites=*)
            ALLOWED_WEBSITES="${1#*=}"
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
if [ -z "$BOOTSTRAP_PASSWORD" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: --bootstrap-password and --postgres-password are required"
    show_usage
    exit 1
fi

# Validate --allowed-websites is provided for non-dev environments
if [ "$DEPLOY_ENV" != "dev" ] && [ -z "$ALLOWED_WEBSITES" ]; then
    echo "ERROR: --allowed-websites is required for --prod and --beta environments"
    echo "  e.g., --allowed-websites beta.example.com or --allowed-websites www.example.com,example.com"
    exit 1
fi

# Validate password lengths
if [ ${#BOOTSTRAP_PASSWORD} -lt 6 ]; then
    echo "ERROR: Bootstrap password must be at least 6 characters"
    exit 1
fi

if [ ${#POSTGRES_PASSWORD} -lt 6 ]; then
    echo "ERROR: Postgres password must be at least 6 characters"
    exit 1
fi

# Auto-generate SECRET_KEY if not provided
if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY=$(openssl rand -hex 32)
    echo "==> Generated SECRET_KEY (save this for future deployments):"
    echo "    $SECRET_KEY"
fi

# Set environment-specific defaults
case $DEPLOY_ENV in
    prod)
        DEFAULT_PORT=8000
        DEFAULT_DATA_DIR="/var/lib/club-server"
        COMPOSE_PROJECT_NAME="club-prod"
        ENVIRONMENT="production"
        REPO_BRANCH="release"
        echo "==> Deploying to PRODUCTION environment (branch: release)"
        ;;
    dev)
        DEFAULT_PORT=8000
        DEFAULT_DATA_DIR="./data"
        COMPOSE_PROJECT_NAME="club-dev"
        ENVIRONMENT="development"
        REPO_BRANCH="main"
        echo "==> Deploying to DEVELOPMENT environment (branch: main)"
        ;;
    beta|*)
        DEFAULT_PORT=8001
        DEFAULT_DATA_DIR="/var/lib/club-server-beta"
        COMPOSE_PROJECT_NAME="club-beta"
        ENVIRONMENT="production"  # Beta runs in production mode but with beta CORS
        REPO_BRANCH="main"
        echo "==> Deploying to BETA environment (branch: main)"
        ;;
esac

# Build CORS origins from --allowed-websites
if [ "$DEPLOY_ENV" = "dev" ]; then
    CORS_ALLOWED_ORIGINS="*"
else
    # Convert comma-separated domains to https:// prefixed origins
    CORS_ALLOWED_ORIGINS=$(echo "$ALLOWED_WEBSITES" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's|^|https://|' | tr '\n' ',' | sed 's/,$//')
fi

# Apply custom overrides
PORT="${CUSTOM_PORT:-$DEFAULT_PORT}"
DATA_DIR="${CUSTOM_DATA_DIR:-$DEFAULT_DATA_DIR}"

# Configuration
POSTGRES_DB="myclub"
POSTGRES_USER="myclub"

echo "==> Environment: $DEPLOY_ENV"
echo "    Branch: $REPO_BRANCH"
echo "    Port: $PORT"
echo "    Data directory: $DATA_DIR"
echo "    CORS origins: $CORS_ALLOWED_ORIGINS"
echo "    Project name: $COMPOSE_PROJECT_NAME"

echo "==> Creating data directories..."
if [ "$DEPLOY_ENV" = "dev" ]; then
    # For dev mode, don't use sudo (macOS local development)
    mkdir -p "$DATA_DIR/db"
    mkdir -p "$DATA_DIR/uploads"
    mkdir -p "$DATA_DIR/static"
else
    sudo mkdir -p "$DATA_DIR/db"
    sudo mkdir -p "$DATA_DIR/uploads"
    sudo mkdir -p "$DATA_DIR/static"
    sudo chown -R $(id -u):$(id -g) "$DATA_DIR"
fi

# Save deployment config (non-secret settings only)
DEPLOY_CONFIG="$DATA_DIR/.deploy.env"
echo "==> Saving deployment config to $DEPLOY_CONFIG..."
if [ "$DEPLOY_ENV" = "dev" ]; then
    cat > "$DEPLOY_CONFIG" << EOF
DEPLOY_ENV=$DEPLOY_ENV
PORT=$PORT
DATA_DIR=$DATA_DIR
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
ENVIRONMENT=$ENVIRONMENT
REPO_BRANCH=$REPO_BRANCH
ALLOWED_WEBSITES=$ALLOWED_WEBSITES
EOF
else
    sudo tee "$DEPLOY_CONFIG" > /dev/null << EOF
DEPLOY_ENV=$DEPLOY_ENV
PORT=$PORT
DATA_DIR=$DATA_DIR
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
ENVIRONMENT=$ENVIRONMENT
REPO_BRANCH=$REPO_BRANCH
ALLOWED_WEBSITES=$ALLOWED_WEBSITES
EOF
    sudo chown $(id -u):$(id -g) "$DEPLOY_CONFIG"
fi
chmod 600 "$DEPLOY_CONFIG"

echo "==> Setting up environment..."

# Determine port binding
if [ "$DEPLOY_ENV" = "dev" ]; then
    SERVER_PORT="${PORT}:8000"
    echo "    Dev mode: Server exposed on port $PORT"
else
    SERVER_PORT="127.0.0.1:${PORT}:8000"
    echo "    Server bound to localhost:$PORT (use nginx to proxy)"
fi

# Export environment variables for docker-compose
export POSTGRES_DB
export POSTGRES_USER
export POSTGRES_PASSWORD
export SECRET_KEY
export BOOTSTRAP_PASSWORD
export DATA_DIR
export SERVER_PORT
export RESET_DB
export GITHUB_TOKEN
export COMPOSE_PROJECT_NAME
export CORS_ALLOWED_ORIGINS
export ENVIRONMENT
export REPO_BRANCH

echo "==> Stopping existing containers for $COMPOSE_PROJECT_NAME..."
docker compose -p "$COMPOSE_PROJECT_NAME" down 2>/dev/null || true

if [ "$RESET_DB" = true ]; then
    echo "==> Removing database data (--reset)..."
    if [ "$DEPLOY_ENV" = "dev" ]; then
        rm -rf "$DATA_DIR/db"/*
        rm -rf "$DATA_DIR/db"/.*  2>/dev/null || true
    else
        sudo rm -rf "$DATA_DIR/db"/*
        sudo rm -rf "$DATA_DIR/db"/.* 2>/dev/null || true
    fi
    echo "    Database data cleared from $DATA_DIR/db"
fi

echo "==> Building and starting containers..."
docker compose -p "$COMPOSE_PROJECT_NAME" build --no-cache
docker compose -p "$COMPOSE_PROJECT_NAME" up -d

# Function to wait for containers to become healthy
wait_for_healthy() {
    local timeout=${1:-120}
    local interval=${2:-3}
    local start_time=$(date +%s)
    local elapsed=0

    local db_container="${COMPOSE_PROJECT_NAME}-postgres"
    local server_container="${COMPOSE_PROJECT_NAME}-server"

    echo "==> Waiting for services to become healthy (timeout: ${timeout}s)..."

    while [ $elapsed -lt $timeout ]; do
        # Get health status of both containers
        local db_health=$(docker inspect --format='{{.State.Health.Status}}' "$db_container" 2>/dev/null || echo "unknown")
        local server_health=$(docker inspect --format='{{.State.Health.Status}}' "$server_container" 2>/dev/null || echo "unknown")

        # Check if server container is running at all
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

        # Display current status
        printf "\r  [%3ds] db: %-10s | server: %-10s" "$elapsed" "$db_health" "$server_health"

        # Check if both are healthy
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
if ! wait_for_healthy 120 3; then
    exit 1
fi

echo ""
echo "==> Deployment complete!"
echo ""
echo "Environment: $DEPLOY_ENV (branch: $REPO_BRANCH)"
echo "Services:"
docker compose -p "$COMPOSE_PROJECT_NAME" ps
echo ""
if [ "$DEPLOY_ENV" = "dev" ]; then
    echo "Server accessible at: http://localhost:$PORT"
    echo "Health check: curl http://localhost:$PORT/health"
else
    echo "Server bound to localhost:$PORT (use nginx to proxy)"
    echo "Next step: sudo ./setup-nginx.sh --domain <server_domain> --port $PORT"
fi
echo ""
echo "Save these credentials securely:"
echo "  Bootstrap password: $BOOTSTRAP_PASSWORD"
echo "  Postgres password:  $POSTGRES_PASSWORD"
echo "  Secret key:         $SECRET_KEY"
echo ""
echo "Data directories:"
echo "  Database: $DATA_DIR/db"
echo "  Uploads:  $DATA_DIR/uploads"
echo "  Static:   $DATA_DIR/static"
