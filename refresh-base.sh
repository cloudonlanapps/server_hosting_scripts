#!/bin/bash
set -euo pipefail

# Build this host's template image from Dockerfile.base: the server's system
# layer (apt packages, ImageMagick, pip, uv), which every deploy's image starts
# FROM. Nothing in it is secret or product-specific, so every product on this
# host at the same tooling version shares one.
#
# The tag is server_hosting_base:<first 12 hex of sha256(Dockerfile.base)>, so a
# tooling version that changes Dockerfile.base gets a template of its own and
# one that does not reuses the one already here.
#
# Usage:
#   ./refresh-base.sh                 Rebuild from scratch: pull the newest
#                                     python image, take every Debian update.
#                                     Run on each host before a release.
#   ./refresh-base.sh --if-missing    Build only when this host has no template
#                                     for this Dockerfile.base (deploy.sh).
#   ./refresh-base.sh --print-tag     Print the tag and exit.
#
# Options:
#   --mirror URL            Debian mirror for this build, e.g.
#                           http://mirror.sg.gs/debian (or DEBIAN_MIRROR)
#   --security-mirror URL   Debian security mirror, e.g.
#                           http://mirror.sg.gs/debian-security
#                           (or DEBIAN_SECURITY_MIRROR)

cd "$(dirname "$0")"

MODE=refresh
MIRROR="${DEBIAN_MIRROR:-}"
SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --if-missing) MODE=if-missing ;;
        --print-tag) MODE=print-tag ;;
        --mirror) shift; MIRROR="${1:?--mirror needs a URL}" ;;
        --security-mirror) shift; SECURITY_MIRROR="${1:?--security-mirror needs a URL}" ;;
        -h|--help) sed -n '4,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

HASH="$(sha256sum Dockerfile.base | cut -c1-12)"
[ ${#HASH} -eq 12 ] || { echo "ERROR: could not hash Dockerfile.base" >&2; exit 1; }
TAG="server_hosting_base:$HASH"

if [ "$MODE" = print-tag ]; then
    echo "$TAG"
    exit 0
fi

# Present, absent, or docker itself failing: only "No such image" means absent.
have_template() {
    local err
    if err="$(docker image inspect --format '{{.Id}}' "$TAG" 2>&1 >/dev/null)"; then
        return 0
    fi
    case "$err" in
        *"No such image"*) return 1 ;;
        *) echo "ERROR: docker image inspect $TAG failed: $err" >&2; exit 1 ;;
    esac
}

if [ "$MODE" = if-missing ] && have_template; then
    echo "==> Template $TAG is here; built $(docker run --rm "$TAG" sed -n 's/^built: //p' /etc/server_hosting_base.txt)"
    exit 0
fi

echo "==> Building template $TAG from scratch"
[ -n "$MIRROR" ] && echo "    Debian mirror: $MIRROR"
[ -n "$SECURITY_MIRROR" ] && echo "    Debian security mirror: $SECURITY_MIRROR"

# --pull and --no-cache: a refresh is for taking updates, so nothing is reused.
# The build context is empty: Dockerfile.base copies no file.
EMPTY_CONTEXT="$(mktemp -d)"
trap 'rmdir "$EMPTY_CONTEXT"' EXIT
docker build --pull --no-cache \
    --build-arg "DEBIAN_MIRROR=$MIRROR" \
    --build-arg "DEBIAN_SECURITY_MIRROR=$SECURITY_MIRROR" \
    -f Dockerfile.base -t "$TAG" "$EMPTY_CONTEXT"

echo "==> Template $TAG built:"
docker run --rm "$TAG" sed -n '1,6s/^/    /p' /etc/server_hosting_base.txt
echo "    (full package list: docker run --rm $TAG cat /etc/server_hosting_base.txt)"
