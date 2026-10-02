#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--conf FILE] [--force] [--dry-run]
#
# Options:
#   --domain DOMAIN     Full domain name for nginx server_name (required)
#   --port PORT         Backend port to proxy to (required)
#   --conf FILE         Host conf whose NGINX_* values override security.conf
#   --force             Overwrite existing config (creates backup first)
#   --dry-run           Print the rate-limit zones and the vhost; change nothing
#
# Examples:
#   sudo ./setup-nginx.sh --domain member.example.com --port 8001
#   sudo ./setup-nginx.sh --domain api.example.com --port 8000
#   sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force

DOMAIN=""
PORT=""
FORCE_MODE=false
HOST_CONF=""
DRY_RUN=false

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--conf FILE] [--force] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --domain DOMAIN     Full domain name for nginx server_name (required)"
            echo "  --port PORT         Backend port to proxy to (required)"
            echo "  --conf FILE         Host conf whose NGINX_* values override security.conf"
            echo "  --force             Overwrite existing config (creates backup first)"
            echo "  --dry-run           Print the rate-limit zones and the vhost; change nothing"
            echo ""
            echo "Examples:"
            echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001"
            echo "  sudo ./setup-nginx.sh --domain api.example.com --port 8000"
            echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force"
            exit 0
            ;;
        --domain)
            shift
            DOMAIN="$1"
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            ;;
        --port)
            shift
            PORT="$1"
            ;;
        --port=*)
            PORT="${1#*=}"
            ;;
        --conf)
            shift
            HOST_CONF="$1"
            ;;
        --conf=*)
            HOST_CONF="${1#*=}"
            ;;
        --force)
            FORCE_MODE=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        *)
            # An unknown option used to be skipped silently, which is how
            # --conf went unread for a month. Refuse it instead.
            echo "ERROR: unknown option: $1 (see --help)"
            exit 1
            ;;
    esac
    shift
done

if [ -z "$DOMAIN" ] || [ -z "$PORT" ]; then
    echo "Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--conf FILE] [--force] [--dry-run]"
    echo ""
    echo "Options:"
    echo "  --domain DOMAIN     Full domain name for nginx server_name (required)"
    echo "  --port PORT         Backend port to proxy to (required)"
    echo "  --conf FILE         Host conf whose NGINX_* values override security.conf"
    echo "  --force             Overwrite existing config (creates backup first)"
    echo "  --dry-run           Print the rate-limit zones and the vhost; change nothing"
    echo ""
    echo "Examples:"
    echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001"
    echo "  sudo ./setup-nginx.sh --domain api.example.com --port 8000"
    echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force"
    exit 1
fi

# Load security.conf for rate limiting values (if available)
SECURITY_CONF="${SCRIPT_DIR}/security.conf"
if [ -f "$SECURITY_CONF" ]; then
    source "$SECURITY_CONF"
    echo "==> Loaded rate limiting config from $SECURITY_CONF"
else
    echo "==> security.conf not found, using defaults for rate limiting"
    NGINX_RATE_AUTH="5r/s"
    NGINX_RATE_API="10r/s"
    NGINX_RATE_GENERAL="20r/s"
    NGINX_ZONE_SIZE="10m"
    NGINX_AUTH_BURST=10
    NGINX_AUTH_CONN_LIMIT=10
    NGINX_API_BURST=20
    NGINX_API_CONN_LIMIT=20
    NGINX_GENERAL_BURST=30
    NGINX_GENERAL_CONN_LIMIT=20
    NGINX_CLIENT_MAX_BODY_SIZE="20M"
fi
# Defaults for settings that a security.conf older than them does not carry.
NGINX_AUTH_PATH="${NGINX_AUTH_PATH:-/api/v1/auth/}"
NGINX_API_PATH="${NGINX_API_PATH:-/api/}"
NGINX_PUBLIC_WRITE_PATH="${NGINX_PUBLIC_WRITE_PATH:-}"
NGINX_RATE_PUBLIC_WRITE="${NGINX_RATE_PUBLIC_WRITE:-3r/m}"
NGINX_PUBLIC_WRITE_BURST="${NGINX_PUBLIC_WRITE_BURST:-5}"

# The host conf wins over security.conf: it is where a deployment says which
# paths its app serves and how large its uploads are.
if [ -n "$HOST_CONF" ]; then
    if [ ! -f "$HOST_CONF" ]; then
        echo "ERROR: --conf file not found: $HOST_CONF"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$HOST_CONF"
    echo "==> Loaded overrides from $HOST_CONF"
fi

# A location path goes into the vhost verbatim, so refuse anything that is not
# a plain absolute path rather than write a config nginx rejects, or one it
# accepts with a different meaning.
check_path() {  # check_path <name> <value> <required: yes|no>
    local name="$1" value="$2"
    if [ -z "$value" ]; then
        [ "$3" = no ] && return 0
        echo "ERROR: $name is empty"
        exit 1
    fi
    case "$value" in
        /*) ;;
        *) echo "ERROR: $name must start with '/': $value"; exit 1 ;;
    esac
    case "$value" in
        *[[:space:]\;\{\}\"\'\$]*)
            echo "ERROR: $name holds a character nginx would misread: $value"
            exit 1 ;;
    esac
}
check_path NGINX_AUTH_PATH "$NGINX_AUTH_PATH" yes
check_path NGINX_API_PATH "$NGINX_API_PATH" yes
check_path NGINX_PUBLIC_WRITE_PATH "$NGINX_PUBLIC_WRITE_PATH" no

render_rate_limiting() {
    cat << RATE_EOF
# Rate limiting zones (generated by setup-nginx.sh)
limit_req_zone \$binary_remote_addr zone=api_limit:${NGINX_ZONE_SIZE} rate=${NGINX_RATE_API};
limit_req_zone \$binary_remote_addr zone=auth_limit:${NGINX_ZONE_SIZE} rate=${NGINX_RATE_AUTH};
limit_req_zone \$binary_remote_addr zone=general_limit:${NGINX_ZONE_SIZE} rate=${NGINX_RATE_GENERAL};
limit_req_zone \$binary_remote_addr zone=public_write_limit:${NGINX_ZONE_SIZE} rate=${NGINX_RATE_PUBLIC_WRITE};
limit_conn_zone \$binary_remote_addr zone=conn_limit:${NGINX_ZONE_SIZE};
RATE_EOF
}

# The public write location, or nothing. An exact match (`location =`) always
# wins over the prefix locations below, wherever it is written.
render_public_write_location() {
    [ -n "$NGINX_PUBLIC_WRITE_PATH" ] || return 0
    cat << PUBLIC_EOF


    # Rate limiting for the one unauthenticated write path (strictest)
    location = ${NGINX_PUBLIC_WRITE_PATH} {
        limit_req zone=public_write_limit burst=${NGINX_PUBLIC_WRITE_BURST} nodelay;
        limit_req_status 429;
        limit_conn conn_limit ${NGINX_AUTH_CONN_LIMIT};

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
PUBLIC_EOF
}

render_site() {
    cat << NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Allow certbot challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }$(render_public_write_location)

    # Rate limiting for auth endpoints (stricter)
    location ${NGINX_AUTH_PATH} {
        limit_req zone=auth_limit burst=${NGINX_AUTH_BURST} nodelay;
        limit_conn conn_limit ${NGINX_AUTH_CONN_LIMIT};

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Rate limiting for API endpoints
    location ${NGINX_API_PATH} {
        limit_req zone=api_limit burst=${NGINX_API_BURST} nodelay;
        limit_conn conn_limit ${NGINX_API_CONN_LIMIT};

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # General rate limiting for other requests
    location / {
        limit_req zone=general_limit burst=${NGINX_GENERAL_BURST} nodelay;
        limit_conn conn_limit ${NGINX_GENERAL_CONN_LIMIT};

        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support (if needed)
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 4k;
        proxy_buffers 8 4k;
    }

    # Increase max body size for file uploads
    client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};
}
NGINX_EOF
}

if [ "$DRY_RUN" = true ]; then
    echo "==> --dry-run: nothing is written"
    echo
    echo "### /etc/nginx/conf.d/rate-limiting.conf"
    render_rate_limiting
    echo
    echo "### /etc/nginx/sites-available/$DOMAIN"
    render_site
    exit 0
fi

echo "==> Setting up nginx for $DOMAIN -> localhost:$PORT"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo ./setup-nginx.sh --domain $DOMAIN --port $PORT"
    exit 1
fi

# Define config path
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"

# Check if config already exists
if [ -f "$NGINX_CONF" ]; then
    # Check if it has SSL configured
    if grep -q "ssl_certificate" "$NGINX_CONF" 2>/dev/null; then
        if [ "$FORCE_MODE" = true ]; then
            # Create backup before overwriting
            BACKUP_FILE="${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
            echo "==> Config exists with SSL. Creating backup: $BACKUP_FILE"
            cp "$NGINX_CONF" "$BACKUP_FILE"
            echo "    Backup created. Proceeding with --force..."
        else
            echo ""
            echo "=========================================="
            echo "CONFIG ALREADY EXISTS WITH SSL"
            echo "=========================================="
            echo ""
            echo "File: $NGINX_CONF"
            echo ""
            echo "This config already has SSL/HTTPS configured by certbot."
            echo "Overwriting would LOSE your SSL settings."
            echo ""
            echo "Options:"
            echo "  1. Do nothing (recommended if it's working)"
            echo "  2. Use --force to recreate (backup will be created)"
            echo "     sudo ./setup-nginx.sh --domain $DOMAIN --port $PORT --force"
            echo ""
            echo "To view current config:"
            echo "  cat $NGINX_CONF"
            echo ""
            exit 0
        fi
    else
        # Config exists but no SSL - safe to update, but still backup
        BACKUP_FILE="${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)"
        echo "==> Config exists (no SSL). Creating backup: $BACKUP_FILE"
        cp "$NGINX_CONF" "$BACKUP_FILE"
    fi
fi

echo "==> Setting up nginx for $DOMAIN (port $PORT)..."

# Install nginx if not present
if ! command -v nginx &> /dev/null; then
    echo "==> Installing nginx..."
    apt-get update
    apt-get install -y nginx
fi

# Install certbot if not present
if ! command -v certbot &> /dev/null; then
    echo "==> Installing certbot..."
    apt-get update
    apt-get install -y certbot python3-certbot-nginx
fi

# Create default server block to reject direct IP access (only if it doesn't exist)
if [ ! -f /etc/nginx/sites-available/default ] || ! grep -q "default_server" /etc/nginx/sites-available/default 2>/dev/null; then
    echo "==> Creating default server block (blocks direct IP access)..."
    cat > /etc/nginx/sites-available/default << 'DEFAULT_EOF'
# Default server - reject requests that don't match any server_name
# This blocks direct IP access and unknown hosts
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;

    server_name _;

    # Self-signed cert for SSL rejection (required for 443)
    # These will be auto-generated if they don't exist
    ssl_certificate /etc/nginx/ssl/default.crt;
    ssl_certificate_key /etc/nginx/ssl/default.key;

    # Return 444 (connection closed without response)
    return 444;
}
DEFAULT_EOF
fi

# Generate self-signed cert for default server (to reject HTTPS on IP)
if [ ! -f /etc/nginx/ssl/default.crt ]; then
    echo "==> Generating self-signed cert for default server..."
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/default.key \
        -out /etc/nginx/ssl/default.crt \
        -subj "/CN=invalid"
fi

ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default

# Create rate limiting zones (idempotent - always overwrite)
echo "==> Creating rate limiting zones..."
render_rate_limiting > /etc/nginx/conf.d/rate-limiting.conf

# Create nginx config for the domain
echo "==> Creating nginx configuration for $DOMAIN -> localhost:$PORT..."
render_site > "$NGINX_CONF"

# Enable the site
echo "==> Enabling site..."
ln -sf "$NGINX_CONF" "/etc/nginx/sites-enabled/$DOMAIN"

# Test nginx configuration
echo "==> Testing nginx configuration..."
nginx -t

# Reload nginx
echo "==> Reloading nginx..."
systemctl reload nginx

# Check if server is reachable before requesting certificate
echo "==> Verifying server is accessible on port $PORT..."
if ! curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/health" | grep -q "200"; then
    echo "WARNING: Backend server not responding on port $PORT"
    echo "Make sure Docker containers are running: docker ps"
    echo ""
    echo "Nginx is configured. Run certbot manually after server is up:"
    echo "  sudo certbot --nginx -d $DOMAIN"
    exit 0
fi

# Request SSL certificate
echo "==> Requesting SSL certificate from Let's Encrypt..."
echo ""
echo "You will be prompted for your email address."
echo ""

certbot --nginx -d "$DOMAIN"

echo ""
echo "==> Setup complete!"
echo ""
echo "Your API is now available at: https://$DOMAIN"
echo ""
echo "SSL certificate will auto-renew. Test renewal with:"
echo "  sudo certbot renew --dry-run"
echo ""
echo "To check nginx status:"
echo "  sudo systemctl status nginx"
echo ""
echo "To view nginx logs:"
echo "  sudo tail -f /var/log/nginx/access.log"
echo "  sudo tail -f /var/log/nginx/error.log"
