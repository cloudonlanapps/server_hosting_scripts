#!/bin/bash
set -e

# Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--force]
#
# Options:
#   --domain DOMAIN     Full domain name for nginx server_name (required)
#   --port PORT         Backend port to proxy to (required)
#   --force             Overwrite existing config (creates backup first)
#
# Examples:
#   sudo ./setup-nginx.sh --domain member.example.com --port 8001
#   sudo ./setup-nginx.sh --domain api.example.com --port 8000
#   sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force

DOMAIN=""
PORT=""
FORCE_MODE=false

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--force]"
            echo ""
            echo "Options:"
            echo "  --domain DOMAIN     Full domain name for nginx server_name (required)"
            echo "  --port PORT         Backend port to proxy to (required)"
            echo "  --force             Overwrite existing config (creates backup first)"
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
        --force)
            FORCE_MODE=true
            ;;
    esac
    shift
done

if [ -z "$DOMAIN" ] || [ -z "$PORT" ]; then
    echo "Usage: sudo ./setup-nginx.sh --domain <domain> --port <port> [--force]"
    echo ""
    echo "Options:"
    echo "  --domain DOMAIN     Full domain name for nginx server_name (required)"
    echo "  --port PORT         Backend port to proxy to (required)"
    echo "  --force             Overwrite existing config (creates backup first)"
    echo ""
    echo "Examples:"
    echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001"
    echo "  sudo ./setup-nginx.sh --domain api.example.com --port 8000"
    echo "  sudo ./setup-nginx.sh --domain member.example.com --port 8001 --force"
    exit 1
fi

echo "==> Setting up nginx for $DOMAIN -> localhost:$PORT"
esac

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

# Create nginx config for the domain
echo "==> Creating nginx configuration for $DOMAIN -> localhost:$PORT..."
cat > "$NGINX_CONF" << NGINX_EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    # Allow certbot challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Proxy all other requests to the FastAPI server
    location / {
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
    client_max_body_size 20M;
}
NGINX_EOF

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
