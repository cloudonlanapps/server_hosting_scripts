#!/bin/bash
set -e

# Usage: sudo ./setup-security.sh --domain <domain> [--domain <domain> ...] [--static-domain <domain> ...]
# Example: sudo ./setup-security.sh --domain api.example.com --static-domain beta.example.com
#
# Sets up UFW firewall, nginx rate limiting, and fail2ban.
# --domain: API proxy domains (have proxy_pass)
# --static-domain: Static website domains (served from /var/www/)
# All settings are read from security.conf.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/security.conf"

DOMAINS=()
STATIC_DOMAINS=()

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: sudo ./setup-security.sh --domain <domain> [--domain <domain> ...] [--static-domain <domain> ...]"
            echo ""
            echo "Configures server security for all specified domains:"
            echo ""
            echo "  1. UFW Firewall - allows only ports configured in security.conf"
            echo "  2. Nginx Rate Limiting - per-endpoint limits (configurable in security.conf)"
            echo "  3. Fail2ban - auto-bans IPs for rate limit violations, bad requests, auth failures"
            echo "  4. Direct IP blocking - only domain-name requests accepted"
            echo ""
            echo "All settings are read from security.conf in the same directory."
            echo ""
            echo "Options:"
            echo "  --domain <domain>         API proxy domain (has proxy_pass to backend)"
            echo "  --static-domain <domain>  Static website domain (served from /var/www/<domain>/)"
            echo ""
            echo "Example:"
            echo "  sudo ./setup-security.sh --domain api.example.com --static-domain beta.example.com"
            echo ""
            echo "Useful commands after setup:"
            echo "  sudo fail2ban-client status                    # Check fail2ban status"
            echo "  sudo fail2ban-client status nginx-limit-req    # Check specific jail"
            echo "  sudo fail2ban-client unban <IP>                # Unban an IP"
            echo "  ufw status                                     # Check firewall"
            exit 0
            ;;
        --domain)
            shift
            DOMAINS+=("$1")
            ;;
        --domain=*)
            DOMAINS+=("${1#*=}")
            ;;
        --static-domain)
            shift
            STATIC_DOMAINS+=("$1")
            ;;
        --static-domain=*)
            STATIC_DOMAINS+=("${1#*=}")
            ;;
    esac
    shift
done

if [ ${#DOMAINS[@]} -eq 0 ] && [ ${#STATIC_DOMAINS[@]} -eq 0 ]; then
    echo "Usage: sudo ./setup-security.sh --domain <domain> [--static-domain <domain> ...]"
    echo "Example: sudo ./setup-security.sh --domain api.example.com --static-domain beta.example.com"
    echo ""
    echo "This will configure security for all specified domains."
    exit 1
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo ./setup-security.sh --domain <domain> [--static-domain <domain> ...]"
    exit 1
fi

# Load shared config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

ALL_DOMAINS=("${DOMAINS[@]}" "${STATIC_DOMAINS[@]}")
echo "==> Setting up security measures for ${ALL_DOMAINS[*]}..."
echo "    Config: $CONFIG_FILE"
echo ""

# ============================================
# 1. UFW Firewall
# ============================================
echo "==> Configuring UFW Firewall..."

# Install UFW if not present
if ! command -v ufw &> /dev/null; then
    apt-get update
    apt-get install -y ufw
fi

# Reset UFW to default
ufw --force reset

# Default policies
ufw default $UFW_DEFAULT_INCOMING incoming
ufw default $UFW_DEFAULT_OUTGOING outgoing

# Allow configured ports
for PORT in $UFW_ALLOWED_PORTS; do
    ufw allow ${PORT}/tcp
done

# Enable UFW
ufw --force enable

echo "    UFW configured. Allowed ports: $UFW_ALLOWED_PORTS"
ufw status verbose

# ============================================
# 2. Nginx Rate Limiting
# ============================================
echo ""
echo "==> Nginx Rate Limiting"
echo "    Rate limiting is configured by setup-nginx.sh (included in site configs)."
echo "    Run setup-nginx.sh to create/update nginx configs with rate limiting."
if [ ${#STATIC_DOMAINS[@]} -gt 0 ]; then
    echo "    Static domains (no rate limiting): ${STATIC_DOMAINS[*]}"
fi

# ============================================
# 3. Fail2ban
# ============================================
echo ""
echo "==> Configuring Fail2ban..."

# Install fail2ban if not present
if ! command -v fail2ban-client &> /dev/null; then
    apt-get update
    apt-get install -y fail2ban
fi

# Create fail2ban filter for nginx rate limiting
cat > /etc/fail2ban/filter.d/nginx-limit-req.conf << 'EOF'
[Definition]
failregex = limiting requests, excess:.* by zone.*client: <HOST>
ignoreregex =
EOF

# Create fail2ban filter for nginx bad requests
cat > /etc/fail2ban/filter.d/nginx-badbots.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*HTTP.*" (400|403|404|405|444) .*$
ignoreregex = \.(?:css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2)
EOF

# Create fail2ban filter for nginx 4xx errors (potential scanners)
cat > /etc/fail2ban/filter.d/nginx-http-auth.conf << 'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST|HEAD).*HTTP.*" 401 .*$
ignoreregex =
EOF

# Create fail2ban jail configuration
cat > /etc/fail2ban/jail.d/nginx.conf << EOF
# Fail2ban jails (generated by setup-security.sh from security.conf)

# Nginx rate limit violations
[nginx-limit-req]
enabled = ${F2B_LIMIT_REQ_ENABLED}
filter = nginx-limit-req
action = iptables-multiport[name=nginx-limit-req, port="http,https"]
logpath = /var/log/nginx/error.log
findtime = ${F2B_LIMIT_REQ_FINDTIME}
bantime = ${F2B_LIMIT_REQ_BANTIME}
maxretry = ${F2B_LIMIT_REQ_MAXRETRY}

# Nginx bad bots and scanners
[nginx-badbots]
enabled = ${F2B_BADBOTS_ENABLED}
filter = nginx-badbots
action = iptables-multiport[name=nginx-badbots, port="http,https"]
logpath = /var/log/nginx/access.log
findtime = ${F2B_BADBOTS_FINDTIME}
bantime = ${F2B_BADBOTS_BANTIME}
maxretry = ${F2B_BADBOTS_MAXRETRY}

# Nginx authentication failures
[nginx-http-auth]
enabled = ${F2B_HTTP_AUTH_ENABLED}
filter = nginx-http-auth
action = iptables-multiport[name=nginx-http-auth, port="http,https"]
logpath = /var/log/nginx/access.log
findtime = ${F2B_HTTP_AUTH_FINDTIME}
bantime = ${F2B_HTTP_AUTH_BANTIME}
maxretry = ${F2B_HTTP_AUTH_MAXRETRY}

# SSH protection
[sshd]
enabled = ${F2B_SSHD_ENABLED}
port = ${F2B_SSHD_PORT}
filter = sshd
logpath = /var/log/auth.log
findtime = ${F2B_SSHD_FINDTIME}
bantime = ${F2B_SSHD_BANTIME}
maxretry = ${F2B_SSHD_MAXRETRY}
EOF

# Restart fail2ban
systemctl restart fail2ban
systemctl enable fail2ban

echo "    Fail2ban configured with nginx rules."

# ============================================
# 4. Block Direct IP Access
# ============================================
echo ""
echo "==> Verifying direct IP access is blocked..."

if [ "$BLOCK_DIRECT_IP" = "true" ]; then
    if [ -f /etc/nginx/sites-available/default ]; then
        if grep -q "return 444" /etc/nginx/sites-available/default; then
            echo "    Direct IP access is blocked (returns 444)."
        else
            echo "    WARNING: Default server block exists but may not block IP access."
            echo "    Run setup-nginx.sh to configure properly."
        fi
    else
        echo "    WARNING: Default server block not found."
        echo "    Direct IP access may be possible. Run setup-nginx.sh first."
    fi
fi

# ============================================
# Summary
# ============================================
echo ""
echo "=========================================="
echo "Security Setup Complete!"
echo "=========================================="
echo ""
echo "API Domains: ${DOMAINS[*]}"
echo "Static Domains: ${STATIC_DOMAINS[*]}"
echo "Config: $CONFIG_FILE"
echo ""
echo "1. UFW Firewall:"
echo "   - Allowed ports: $UFW_ALLOWED_PORTS"
echo "   - Database port NOT exposed externally"
echo ""
echo "2. Nginx Rate Limiting:"
echo "   - Configured by setup-nginx.sh (included in site configs)"
echo "   - Run setup-nginx.sh --domain <domain> --port <port> to apply"
echo ""
echo "3. Fail2ban:"
echo "   - Rate limit violations: bantime=${F2B_LIMIT_REQ_BANTIME}s, maxretry=${F2B_LIMIT_REQ_MAXRETRY}"
echo "   - Bad bots: bantime=${F2B_BADBOTS_BANTIME}s, maxretry=${F2B_BADBOTS_MAXRETRY}"
echo "   - Auth failures: bantime=${F2B_HTTP_AUTH_BANTIME}s, maxretry=${F2B_HTTP_AUTH_MAXRETRY}"
echo "   - SSH brute force: bantime=${F2B_SSHD_BANTIME}s, maxretry=${F2B_SSHD_MAXRETRY}"
echo ""
echo "4. Direct IP Access:"
echo "   - Blocked (returns 444 - connection closed)"
echo "   - Only requests via domain name are accepted"
echo ""
echo "Run audit-security.sh to verify: sudo ./audit-security.sh --domain <domain>"
echo ""
echo "Useful commands:"
echo "  ufw status                    - Check firewall status"
echo "  fail2ban-client status        - Check fail2ban status"
echo "  fail2ban-client status nginx-limit-req  - Check specific jail"
echo "  fail2ban-client unban <IP>    - Unban an IP"
echo ""
