#!/bin/bash
set -e

# Usage: sudo ./setup-nginx-conf.sh <conf-file> <env>
#
# Wrapper around setup-nginx.sh. Resolves the environment's port and the API's
# domain from the host conf, then configures nginx and requests a certificate
# for that domain.
#
# Needs root. Does NOT need 'pass' — no secrets are read.
#
# Run once per public environment. There is no re-install: certbot rewrites the
# vhost in place, so a second run would drop a live site to plain HTTP. To redo
# it, remove the file under /etc/nginx/sites-available/ first, or pass --force.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -lt 2 ]; then
    echo "Usage: sudo $0 <conf-file> <env> [extra args for setup-nginx.sh]"
    exit 1
fi

CONF_FILE="$1"
ENV="$2"
shift 2

if [ ! -f "$CONF_FILE" ]; then
    echo "ERROR: Conf file not found: $CONF_FILE"
    exit 1
fi

# shellcheck disable=SC1090
source "$CONF_FILE"

if [ -z "${ENVS+x}" ] || [ ${#ENVS[@]} -eq 0 ]; then
    echo "ERROR: $CONF_FILE must define ENVS=(...) with at least one entry"
    exit 1
fi

ENV_OK=false
for e in "${ENVS[@]}"; do
    [ "$e" = "$ENV" ] && ENV_OK=true && break
done
if [ "$ENV_OK" = false ]; then
    echo "ERROR: Unknown env '$ENV'. Allowed: ${ENVS[*]}"
    exit 1
fi

PORT_VAR="${ENV}_PORT"
DOMAIN_VAR="${ENV}_API_DOMAIN"
PORT="${!PORT_VAR:-}"
DOMAIN="${!DOMAIN_VAR:-}"

if [ -z "$PORT" ]; then
    echo "ERROR: $CONF_FILE must define $PORT_VAR"
    exit 1
fi
# Not <env>_ALLOWED_WEBSITES: those are the sites allowed to CALL the API (CORS),
# not where it is served. Naming the vhost after the first of them put the API
# on the website's domain.
if [ -z "$DOMAIN" ]; then
    echo "ERROR: $CONF_FILE defines no $DOMAIN_VAR — '$ENV' has no public API domain."
    echo "       It is taken from the environment's server_base_url, and only an"
    echo "       https:// URL gives one. Re-run the installer if the conf predates it."
    exit 1
fi

# Root last, not first: a wrong conf, a wrong env or an env with no domain are
# all worth learning before being told to re-run under sudo.
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: run as root: sudo $0 $CONF_FILE $ENV"
    exit 1
fi

# Confirm the domain. This requests a public certificate for it and writes a
# vhost, and the domain is the part worth being sure about.
cat <<EOF

    nginx + TLS for
        $DOMAIN   ->  127.0.0.1:$PORT
    environment
        $ENV  (from $CONF_FILE)

EOF
if { true >/dev/tty; } 2>/dev/null; then
    printf 'Request a certificate and write the vhost? [Y/n]: ' > /dev/tty
    read -r GO < /dev/tty || true
    case "${GO:-Y}" in [nN]*) echo "Aborted."; exit 1 ;; esac
fi

exec "$SCRIPT_DIR/setup-nginx.sh" --domain "$DOMAIN" --port "$PORT" --conf "$CONF_FILE" "$@"
