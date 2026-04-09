#!/bin/bash
set -e

# Usage: ./deploy.sh --project NAME --git-url URL --bootstrap-password PASS --postgres-password PASS [options]
#
# Required:
#   --project NAME              Project name (e.g., myproduct). Used to derive all names.
#   --git-url URL               Git repository URL (e.g., https://github.com/org/myproduct_server.git)
#   --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)
#   --postgres-password PASS    Database password (fixed once created, change only with --reset)
#
# Modes:
#   --dev               Development mode (all CORS, port exposed externally)
#   (default)           Server mode: localhost-only binding, requires --allowed-websites
#
# Options:
#   --git-branch BRANCH Git branch to deploy (required in server mode, optional in dev mode)
#   --port PORT         Host port (default: 8001)
#   --reset             Drop all tables before starting (fresh database)
#   --secret-key KEY    JWT signing key (auto-generated if not provided; changing it invalidates existing user sessions)
#   --github-token TOK  GitHub token for cloning private repo
#   --data-dir DIR      Custom data directory (default: ~/.local/share/server_<project>_<branch>)
#   --allowed-websites SITES  Domain(s) for CORS, comma-separated (required in server mode)

show_usage() {
    echo "Usage: ./deploy.sh --project NAME --git-url URL --bootstrap-password PASS --postgres-password PASS [options]"
    echo ""
    echo "Required:"
    echo "  --project NAME              Project name (derives DB, dirs, containers)"
    echo "  --git-url URL               Git repository URL"
    echo "  --bootstrap-password PASS   Password for the bootstrap admin user (can be changed on each run)"
    echo "  --postgres-password PASS    Database password (fixed once created, change only with --reset)"
    echo ""
    echo "Modes:"
    echo "  --dev               Development mode (all CORS, port exposed externally)"
    echo "  (default)           Server mode: localhost-only binding, requires --allowed-websites"
    echo ""
    echo "Options:"
    echo "  --git-branch BRANCH Git branch to deploy (required in server mode, optional in dev mode)"
    echo "  --port PORT         Host port (default: 8001)"
    echo "  --reset             Drop all tables before starting (fresh database)"
    echo "  --secret-key KEY    JWT signing key (auto-generated if not provided; changing it invalidates existing user sessions)"
    echo "  --github-token TOK  GitHub token for cloning private repo"
    echo "  --data-dir DIR      Custom data directory (default: ~/.local/share/server_<project>_<branch>)"
    echo "  --allowed-websites SITES  Domain(s) for CORS, comma-separated (required in server mode)"
    echo ""
    echo "Naming convention (given --project myproduct --git-branch release):"
    echo "  Server entry point:  myproduct_server.main:app"
    echo "  Bootstrap command:   myproduct_bootstrap"
    echo "  DB name & user:      myproduct"
    echo "  Data dir (server):   ~/.local/share/server_myproduct_release"
    echo "  Data dir (dev):      ~/.local/share/server_dev_myproduct"
    echo "  Data dir (dev+branch): ~/.local/share/server_dev_myproduct_feature"
    echo "  Containers:          myproduct-release-server, myproduct-release-postgres, etc."
    echo ""
    echo "Examples:"
    echo "  # Server mode — branch=main, default port 8001:"
    echo "  ./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \\"
    echo "    --bootstrap-password pass123 --postgres-password dbpass123 \\"
    echo "    --git-branch main --allowed-websites beta.example.com"
    echo ""
    echo "  # Server mode — branch=release, port 8000:"
    echo "  ./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \\"
    echo "    --bootstrap-password pass123 --postgres-password dbpass123 \\"
    echo "    --git-branch release --port 8000 --allowed-websites www.example.com,example.com"
    echo ""
    echo "  # Dev mode — clones repo's default branch:"
    echo "  ./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \\"
    echo "    --bootstrap-password pass123 --postgres-password dbpass123 --dev"
    echo ""
    echo "  # Dev mode — specific branch for debugging:"
    echo "  ./deploy.sh --project myproduct --git-url https://github.com/org/myproduct_server.git \\"
    echo "    --bootstrap-password pass123 --postgres-password dbpass123 --dev --git-branch fix/login-bug"
    echo ""
    echo "Prerequisites:"
    echo "  - Docker installed and running"
    echo "  - Current user in the 'docker' group (to run docker without sudo)"
    echo "    Check: groups | grep docker"
    echo "    Fix:   sudo usermod -aG docker \$USER && newgrp docker"
    echo ""
    echo "Data is stored in ~/.local/share/ — no sudo required."
    echo "Back up ~/.local/share/server_<project>_*/ to preserve all deployment data."
}

PROJECT_NAME=""
GIT_URL=""
BOOTSTRAP_PASSWORD=""
POSTGRES_PASSWORD=""
SECRET_KEY=""
GITHUB_TOKEN=""
RESET_DB=false
DEV_MODE=false
GIT_BRANCH=""
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
        --project)
            shift
            PROJECT_NAME="$1"
            ;;
        --project=*)
            PROJECT_NAME="${1#*=}"
            ;;
        --git-url)
            shift
            GIT_URL="$1"
            ;;
        --git-url=*)
            GIT_URL="${1#*=}"
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

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed. Install Docker first."
    exit 1
fi
if ! docker info &> /dev/null; then
    echo "ERROR: Cannot connect to Docker. Is the Docker daemon running?"
    echo "  If your user is not in the 'docker' group, run:"
    echo "    sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi

# Validate required arguments
if [ -z "$PROJECT_NAME" ] || [ -z "$GIT_URL" ] || [ -z "$BOOTSTRAP_PASSWORD" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: --project, --git-url, --bootstrap-password, and --postgres-password are required"
    show_usage
    exit 1
fi

# Server mode requires --git-branch and --allowed-websites
if [ "$DEV_MODE" = false ]; then
    if [ -z "$GIT_BRANCH" ]; then
        echo "ERROR: --git-branch is required in server mode (e.g., --git-branch main, --git-branch release)"
        echo "  Use --dev for development mode (clones repo's default branch)"
        exit 1
    fi
    if [ -z "$ALLOWED_WEBSITES" ]; then
        echo "ERROR: --allowed-websites is required in server mode"
        echo "  e.g., --allowed-websites beta.example.com or --allowed-websites www.example.com,example.com"
        exit 1
    fi
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

# Data directory base
DATA_BASE="${HOME}/.local/share"

# Set environment-specific defaults
if [ "$DEV_MODE" = true ]; then
    DEFAULT_PORT=8001
    if [ -n "$GIT_BRANCH" ]; then
        DEFAULT_DATA_DIR="${DATA_BASE}/server_dev_${PROJECT_NAME}_${GIT_BRANCH}"
    else
        DEFAULT_DATA_DIR="${DATA_BASE}/server_dev_${PROJECT_NAME}"
    fi
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}-dev"
    ENVIRONMENT="development"
    REPO_BRANCH="$GIT_BRANCH"
    echo "==> Deploying to DEVELOPMENT mode (branch: ${GIT_BRANCH:-repo default})"
else
    DEFAULT_PORT=8001
    DEFAULT_DATA_DIR="${DATA_BASE}/server_${PROJECT_NAME}_${GIT_BRANCH}"
    COMPOSE_PROJECT_NAME="${PROJECT_NAME}-${GIT_BRANCH}"
    ENVIRONMENT="production"
    REPO_BRANCH="$GIT_BRANCH"
    echo "==> Deploying branch: $GIT_BRANCH"
fi

# Build CORS origins from --allowed-websites
if [ "$DEV_MODE" = true ]; then
    CORS_ALLOWED_ORIGINS="*"
else
    # Convert comma-separated domains to https:// prefixed origins
    CORS_ALLOWED_ORIGINS=$(echo "$ALLOWED_WEBSITES" | tr ',' '\n' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//' | sed 's|^|https://|' | tr '\n' ',' | sed 's/,$//')
fi

# Apply custom overrides
PORT="${CUSTOM_PORT:-$DEFAULT_PORT}"
DATA_DIR="${CUSTOM_DATA_DIR:-$DEFAULT_DATA_DIR}"

# Configuration derived from project name
POSTGRES_DB="$PROJECT_NAME"
POSTGRES_USER="$PROJECT_NAME"

echo "==> Project: $PROJECT_NAME"
echo "    Git URL: $GIT_URL"
echo "    Branch: ${REPO_BRANCH:-repo default}"
echo "    Port: $PORT"
echo "    Data directory: $DATA_DIR"
echo "    CORS origins: $CORS_ALLOWED_ORIGINS"
echo "    Compose project: $COMPOSE_PROJECT_NAME"

echo "==> Creating data directories..."
mkdir -p "$DATA_DIR/db"
mkdir -p "$DATA_DIR/uploads"
mkdir -p "$DATA_DIR/static"

# Save deployment config (non-secret settings only)
DEPLOY_CONFIG="$DATA_DIR/.deploy.env"
echo "==> Saving deployment config to $DEPLOY_CONFIG..."
cat > "$DEPLOY_CONFIG" << EOF
PROJECT_NAME=$PROJECT_NAME
GIT_URL=$GIT_URL
DEV_MODE=$DEV_MODE
GIT_BRANCH=$GIT_BRANCH
PORT=$PORT
DATA_DIR=$DATA_DIR
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
ENVIRONMENT=$ENVIRONMENT
REPO_BRANCH=$REPO_BRANCH
ALLOWED_WEBSITES=$ALLOWED_WEBSITES
EOF
chmod 600 "$DEPLOY_CONFIG"

echo "==> Setting up environment..."

# Determine port binding
if [ "$DEV_MODE" = true ]; then
    SERVER_PORT="${PORT}:8000"
    echo "    Dev mode: Server exposed on port $PORT"
else
    SERVER_PORT="127.0.0.1:${PORT}:8000"
    echo "    Server bound to localhost:$PORT (use nginx to proxy)"
fi

# Export environment variables for docker-compose
export PROJECT_NAME
export GIT_URL
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
    rm -rf "$DATA_DIR/db"/*
    rm -rf "$DATA_DIR/db"/.* 2>/dev/null || true
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
if ! wait_for_healthy 120 3; then
    exit 1
fi

echo ""
echo "==> Deployment complete!"
echo ""
echo "Branch: $REPO_BRANCH | Port: $PORT"
echo "Services:"
docker compose -p "$COMPOSE_PROJECT_NAME" ps
echo ""
if [ "$DEV_MODE" = true ]; then
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
