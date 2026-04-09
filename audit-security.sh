#!/bin/bash
set -e

# audit-security.sh - Read-only security audit
# Usage: sudo ./audit-security.sh --domain <base_domain>
# Checks server security configuration against security.conf requirements.
# Does NOT make any changes - only reports PASS/FAIL.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/security.conf"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() {
    echo -e "  ${GREEN}[PASS]${NC} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo -e "  ${RED}[FAIL]${NC} $1"
    echo -e "         Expected: $2"
    echo -e "         Actual:   $3"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

warn() {
    echo -e "  ${YELLOW}[WARN]${NC} $1"
    WARN_COUNT=$((WARN_COUNT + 1))
}

# ============================================
# Load config
# ============================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Config file not found: $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"

DOMAINS=()
STATIC_DOMAINS=()

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --help|-h)
            echo "Usage: sudo ./audit-security.sh --domain <domain> [--domain <domain> ...] [--static-domain <domain> ...]"
            echo "Checks server security configuration against security.conf requirements."
            echo "  --domain: API proxy domains"
            echo "  --static-domain: Static website domains"
            echo "Does NOT make any changes - only reports PASS/FAIL."
            exit 0
            ;;
        --domain)
            shift
            DOMAINS+=("${1:-}")
            ;;
        --domain=*)
            DOMAINS+=("${1#*=}")
            ;;
        --static-domain)
            shift
            STATIC_DOMAINS+=("${1:-}")
            ;;
        --static-domain=*)
            STATIC_DOMAINS+=("${1#*=}")
            ;;
    esac
    shift
done

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo: sudo ./audit-security.sh --domain <domain> [--domain <domain> ...]"
    exit 1
fi

echo "=========================================="
echo "Security Audit"
echo "=========================================="
echo "Config: $CONFIG_FILE"
[ ${#DOMAINS[@]} -gt 0 ] && echo "API Domains: ${DOMAINS[*]}"
[ ${#STATIC_DOMAINS[@]} -gt 0 ] && echo "Static Domains: ${STATIC_DOMAINS[*]}"
echo ""

# ============================================
# 1. UFW Firewall
# ============================================
echo "==> UFW Firewall"

# Check UFW is active
UFW_STATUS=$(ufw status 2>/dev/null || echo "not installed")
if echo "$UFW_STATUS" | grep -q "Status: active"; then
    pass "UFW is active"
else
    fail "UFW is active" "active" "inactive or not installed"
fi

# Check default policies
UFW_VERBOSE=$(ufw status verbose 2>/dev/null || echo "")
ACTUAL_INCOMING=$(echo "$UFW_VERBOSE" | grep "Default:" | head -1 | sed 's/.*: //' | awk -F',' '{print $1}' | xargs | awk '{print $1}')
if [ "$ACTUAL_INCOMING" = "$UFW_DEFAULT_INCOMING" ]; then
    pass "Default incoming policy: $UFW_DEFAULT_INCOMING"
else
    fail "Default incoming policy" "$UFW_DEFAULT_INCOMING" "$ACTUAL_INCOMING"
fi

ACTUAL_OUTGOING=$(echo "$UFW_VERBOSE" | grep "Default:" | head -1 | sed 's/.*: //' | awk -F',' '{print $2}' | xargs | awk '{print $1}')
if [ "$ACTUAL_OUTGOING" = "$UFW_DEFAULT_OUTGOING" ]; then
    pass "Default outgoing policy: $UFW_DEFAULT_OUTGOING"
else
    fail "Default outgoing policy" "$UFW_DEFAULT_OUTGOING" "$ACTUAL_OUTGOING"
fi

# Check allowed ports
for PORT in $UFW_ALLOWED_PORTS; do
    if echo "$UFW_STATUS" | grep -q "${PORT}/tcp"; then
        pass "Port ${PORT}/tcp is allowed"
    else
        fail "Port ${PORT}/tcp is allowed" "ALLOW" "not found in UFW rules"
    fi
done

# Check for unexpected ports
ACTUAL_PORTS=$(echo "$UFW_STATUS" | grep "ALLOW" | grep -oP '^\d+' | sort -u)
for ACTUAL_PORT in $ACTUAL_PORTS; do
    if ! echo "$UFW_ALLOWED_PORTS" | grep -qw "$ACTUAL_PORT"; then
        fail "No unexpected ports open" "only $UFW_ALLOWED_PORTS" "port $ACTUAL_PORT is also open"
    fi
done

# ============================================
# 2. Nginx Rate Limiting
# ============================================
echo ""
echo "==> Nginx Rate Limiting"

RATE_CONF="/etc/nginx/conf.d/rate-limiting.conf"
if [ -f "$RATE_CONF" ]; then
    pass "Rate limiting config exists: $RATE_CONF"

    # Check each rate zone
    if grep -q "zone=api_limit.*rate=${NGINX_RATE_API}" "$RATE_CONF"; then
        pass "API rate limit: $NGINX_RATE_API"
    else
        ACTUAL=$(grep "zone=api_limit" "$RATE_CONF" | grep -oP 'rate=\S+' || echo "not found")
        fail "API rate limit" "$NGINX_RATE_API" "$ACTUAL"
    fi

    if grep -q "zone=auth_limit.*rate=${NGINX_RATE_AUTH}" "$RATE_CONF"; then
        pass "Auth rate limit: $NGINX_RATE_AUTH"
    else
        ACTUAL=$(grep "zone=auth_limit" "$RATE_CONF" | grep -oP 'rate=\S+' || echo "not found")
        fail "Auth rate limit" "$NGINX_RATE_AUTH" "$ACTUAL"
    fi

    if grep -q "zone=general_limit.*rate=${NGINX_RATE_GENERAL}" "$RATE_CONF"; then
        pass "General rate limit: $NGINX_RATE_GENERAL"
    else
        ACTUAL=$(grep "zone=general_limit" "$RATE_CONF" | grep -oP 'rate=\S+' || echo "not found")
        fail "General rate limit" "$NGINX_RATE_GENERAL" "$ACTUAL"
    fi
else
    fail "Rate limiting config exists" "$RATE_CONF" "file not found"
fi

# ============================================
# 3. Nginx Site Configs (per domain)
# ============================================
# Helper to audit a single nginx site config
audit_site_config() {
    local SITE_DOMAIN="$1"
    local IS_STATIC="$2"
    local SITE_CONF="/etc/nginx/sites-available/${SITE_DOMAIN}"

    if [ ! -f "$SITE_CONF" ]; then
        warn "Site config not found: $SITE_CONF (skipping)"
        return
    fi

    if [ "$IS_STATIC" = "true" ]; then
        echo "  --- ${SITE_DOMAIN} (static) ---"
    else
        echo "  --- ${SITE_DOMAIN} ---"
    fi

    # API proxy domains: check auth and api rate limits
    if [ "$IS_STATIC" != "true" ]; then
        # Check auth burst
        if grep -q "zone=auth_limit burst=${NGINX_AUTH_BURST}" "$SITE_CONF"; then
            pass "Auth burst=${NGINX_AUTH_BURST}"
        else
            ACTUAL=$(grep "zone=auth_limit" "$SITE_CONF" | grep -oP 'burst=\d+' || echo "not found")
            fail "Auth burst" "burst=${NGINX_AUTH_BURST}" "$ACTUAL"
        fi

        # Check auth conn limit
        if grep -A1 "zone=auth_limit" "$SITE_CONF" | grep -q "conn_limit ${NGINX_AUTH_CONN_LIMIT}"; then
            pass "Auth conn_limit=${NGINX_AUTH_CONN_LIMIT}"
        else
            ACTUAL=$(grep -A2 "zone=auth_limit" "$SITE_CONF" | grep "conn_limit" | grep -oP '\d+' || echo "not found")
            fail "Auth conn_limit" "${NGINX_AUTH_CONN_LIMIT}" "$ACTUAL"
        fi

        # Check API burst
        if grep -q "zone=api_limit burst=${NGINX_API_BURST}" "$SITE_CONF"; then
            pass "API burst=${NGINX_API_BURST}"
        else
            ACTUAL=$(grep "zone=api_limit" "$SITE_CONF" | grep -oP 'burst=\d+' || echo "not found")
            fail "API burst" "burst=${NGINX_API_BURST}" "$ACTUAL"
        fi

        # Check API conn limit
        if grep -A1 "zone=api_limit" "$SITE_CONF" | grep -q "conn_limit ${NGINX_API_CONN_LIMIT}"; then
            pass "API conn_limit=${NGINX_API_CONN_LIMIT}"
        else
            ACTUAL=$(grep -A2 "zone=api_limit" "$SITE_CONF" | grep "conn_limit" | grep -oP '\d+' || echo "not found")
            fail "API conn_limit" "${NGINX_API_CONN_LIMIT}" "$ACTUAL"
        fi
    fi

    # All domains: check general rate limit
    # Check general burst
    if grep -q "zone=general_limit burst=${NGINX_GENERAL_BURST}" "$SITE_CONF"; then
        pass "General burst=${NGINX_GENERAL_BURST}"
    else
        ACTUAL=$(grep "zone=general_limit" "$SITE_CONF" | grep -oP 'burst=\d+' || echo "not found")
        fail "General burst" "burst=${NGINX_GENERAL_BURST}" "$ACTUAL"
    fi

    # Check general conn limit
    if grep -A1 "zone=general_limit" "$SITE_CONF" | grep -q "conn_limit ${NGINX_GENERAL_CONN_LIMIT}"; then
        pass "General conn_limit=${NGINX_GENERAL_CONN_LIMIT}"
    else
        ACTUAL=$(grep -A2 "zone=general_limit" "$SITE_CONF" | grep "conn_limit" | grep -oP '\d+' || echo "not found")
        fail "General conn_limit" "${NGINX_GENERAL_CONN_LIMIT}" "$ACTUAL"
    fi

    # Check client_max_body_size
    if grep -q "client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE}" "$SITE_CONF"; then
        pass "client_max_body_size=${NGINX_CLIENT_MAX_BODY_SIZE}"
    else
        ACTUAL=$(grep "client_max_body_size" "$SITE_CONF" | awk '{print $2}' | tr -d ';' || echo "not found")
        fail "client_max_body_size" "${NGINX_CLIENT_MAX_BODY_SIZE}" "$ACTUAL"
    fi
}

if [ ${#DOMAINS[@]} -gt 0 ] || [ ${#STATIC_DOMAINS[@]} -gt 0 ]; then
    echo ""
    echo "==> Nginx Site Configs"

    for SITE_DOMAIN in "${DOMAINS[@]}"; do
        audit_site_config "$SITE_DOMAIN" "false"
    done

    for SITE_DOMAIN in "${STATIC_DOMAINS[@]}"; do
        audit_site_config "$SITE_DOMAIN" "true"
    done
else
    echo ""
    warn "No domain provided - skipping nginx site config checks."
    echo "       Run with: sudo ./audit-security.sh --domain <domain> [--static-domain <domain> ...]"
fi

# ============================================
# 4. Fail2ban
# ============================================
echo ""
echo "==> Fail2ban"

# Check fail2ban is running
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    pass "Fail2ban service is running"
else
    fail "Fail2ban service is running" "active" "inactive or not installed"
fi

F2B_CONF="/etc/fail2ban/jail.d/nginx.conf"
if [ -f "$F2B_CONF" ]; then
    pass "Fail2ban jail config exists: $F2B_CONF"
else
    fail "Fail2ban jail config exists" "$F2B_CONF" "file not found"
fi

# Function to check a fail2ban jail's settings
check_jail() {
    local JAIL_NAME="$1"
    local LABEL="$2"
    local EXPECTED_ENABLED="$3"
    local EXPECTED_FINDTIME="$4"
    local EXPECTED_BANTIME="$5"
    local EXPECTED_MAXRETRY="$6"

    echo "  --- ${LABEL} (${JAIL_NAME}) ---"

    if [ ! -f "$F2B_CONF" ]; then
        fail "Config file for $JAIL_NAME" "exists" "missing"
        return
    fi

    # Check enabled
    if [ "$EXPECTED_ENABLED" = "true" ]; then
        # Check runtime status
        if fail2ban-client status "$JAIL_NAME" &>/dev/null; then
            pass "$JAIL_NAME is enabled and active"
        else
            fail "$JAIL_NAME is enabled and active" "active" "jail not running"
        fi
    fi

    # Parse values from config file using awk to get jail-specific sections
    # Extract the section for this jail
    local JAIL_SECTION
    JAIL_SECTION=$(awk "/\\[${JAIL_NAME}\\]/,/^\\[/" "$F2B_CONF")

    # Parse value from "key = value" or "key=value" format
    parse_jail_value() {
        echo "$JAIL_SECTION" | grep "^$1" | sed 's/[[:space:]]*=[[:space:]]*/=/' | cut -d'=' -f2 | tr -d '[:space:]'
    }

    # Check findtime
    local ACTUAL_FINDTIME
    ACTUAL_FINDTIME=$(parse_jail_value "findtime")
    if [ "$ACTUAL_FINDTIME" = "$EXPECTED_FINDTIME" ]; then
        pass "findtime = $EXPECTED_FINDTIME"
    else
        fail "findtime" "$EXPECTED_FINDTIME" "${ACTUAL_FINDTIME:-not found}"
    fi

    # Check bantime
    local ACTUAL_BANTIME
    ACTUAL_BANTIME=$(parse_jail_value "bantime")
    if [ "$ACTUAL_BANTIME" = "$EXPECTED_BANTIME" ]; then
        pass "bantime = $EXPECTED_BANTIME"
    else
        fail "bantime" "$EXPECTED_BANTIME" "${ACTUAL_BANTIME:-not found}"
    fi

    # Check maxretry
    local ACTUAL_MAXRETRY
    ACTUAL_MAXRETRY=$(parse_jail_value "maxretry")
    if [ "$ACTUAL_MAXRETRY" = "$EXPECTED_MAXRETRY" ]; then
        pass "maxretry = $EXPECTED_MAXRETRY"
    else
        fail "maxretry" "$EXPECTED_MAXRETRY" "${ACTUAL_MAXRETRY:-not found}"
    fi
}

check_jail "nginx-limit-req" "Rate Limit Violations" \
    "$F2B_LIMIT_REQ_ENABLED" "$F2B_LIMIT_REQ_FINDTIME" "$F2B_LIMIT_REQ_BANTIME" "$F2B_LIMIT_REQ_MAXRETRY"

check_jail "nginx-badbots" "Bad Bots / Scanners" \
    "$F2B_BADBOTS_ENABLED" "$F2B_BADBOTS_FINDTIME" "$F2B_BADBOTS_BANTIME" "$F2B_BADBOTS_MAXRETRY"

check_jail "nginx-http-auth" "HTTP Auth Failures" \
    "$F2B_HTTP_AUTH_ENABLED" "$F2B_HTTP_AUTH_FINDTIME" "$F2B_HTTP_AUTH_BANTIME" "$F2B_HTTP_AUTH_MAXRETRY"

check_jail "sshd" "SSH Brute Force" \
    "$F2B_SSHD_ENABLED" "$F2B_SSHD_FINDTIME" "$F2B_SSHD_BANTIME" "$F2B_SSHD_MAXRETRY"

# Check sshd port in fail2ban config
if [ -f "$F2B_CONF" ]; then
    SSHD_SECTION=$(awk '/\[sshd\]/,/^\[/' "$F2B_CONF")
    ACTUAL_PORT=$(echo "$SSHD_SECTION" | grep "^port" | sed 's/[[:space:]]*=[[:space:]]*/=/' | cut -d'=' -f2 | tr -d '[:space:]')
    if [ "$ACTUAL_PORT" = "$F2B_SSHD_PORT" ]; then
        pass "sshd jail port = $F2B_SSHD_PORT"
    else
        fail "sshd jail port" "$F2B_SSHD_PORT" "${ACTUAL_PORT:-not found}"
    fi
fi

# ============================================
# 5. Direct IP Access
# ============================================
echo ""
echo "==> Direct IP Access"

if [ "$BLOCK_DIRECT_IP" = "true" ]; then
    DEFAULT_SITE="/etc/nginx/sites-available/default"
    if [ -f "$DEFAULT_SITE" ]; then
        if grep -q "return 444" "$DEFAULT_SITE"; then
            pass "Direct IP access is blocked (returns 444)"
        else
            fail "Direct IP access blocked" "return 444 in default server block" "not found"
        fi
    else
        fail "Default server block exists" "$DEFAULT_SITE" "file not found"
    fi
fi

# ============================================
# Summary
# ============================================
echo ""
echo "=========================================="
echo "Audit Summary"
echo "=========================================="
echo -e "  ${GREEN}Passed: $PASS_COUNT${NC}"
echo -e "  ${RED}Failed: $FAIL_COUNT${NC}"
echo -e "  ${YELLOW}Warnings: $WARN_COUNT${NC}"
echo ""

if [ $FAIL_COUNT -eq 0 ]; then
    echo -e "${GREEN}All checks passed!${NC}"
    exit 0
else
    echo -e "${RED}$FAIL_COUNT check(s) failed. Run setup-security.sh to fix.${NC}"
    exit 1
fi
