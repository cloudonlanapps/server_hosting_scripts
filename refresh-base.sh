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
#   ./refresh-base.sh --check         Exit 0 and print when it was built if this
#                                     host has the template, 1 if it has not,
#                                     2 if docker failed (deploy.sh).
#   ./refresh-base.sh --print-tag     Print the tag and exit.
#
# Options:
#   --mirror URL            Debian mirror for this build, e.g.
#                           http://mirror.sg.gs/debian (or DEBIAN_MIRROR)
#   --security-mirror URL   Debian security mirror, e.g.
#                           http://mirror.sg.gs/debian-security
#                           (or DEBIAN_SECURITY_MIRROR)
#   --imagemagick FILE      The ImageMagick AppImage Dockerfile.base pins, to
#                           use instead of downloading it from GitHub (or
#                           IMAGEMAGICK_APPIMAGE). Checked against the same
#                           SHA-256, so a wrong file fails the build.

cd "$(dirname "$0")"

MODE=refresh
MIRROR="${DEBIAN_MIRROR:-}"
SECURITY_MIRROR="${DEBIAN_SECURITY_MIRROR:-}"
IMAGEMAGICK="${IMAGEMAGICK_APPIMAGE:-}"

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE=check ;;
        --print-tag) MODE=print-tag ;;
        --mirror) shift; MIRROR="${1:?--mirror needs a URL}" ;;
        --security-mirror) shift; SECURITY_MIRROR="${1:?--security-mirror needs a URL}" ;;
        --imagemagick) shift; IMAGEMAGICK="${1:?--imagemagick needs a file}" ;;
        -h|--help) sed -n '4,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
        *) echo "ERROR: docker image inspect $TAG failed: $err" >&2; exit 2 ;;
    esac
}

if [ "$MODE" = check ]; then
    have_template || exit 1
    BUILT="$(docker run --rm "$TAG" sed -n 's/^built: //p' /etc/server_hosting_base.txt)" \
        || { echo "ERROR: could not read $TAG's build record" >&2; exit 2; }
    echo "$BUILT"
    exit 0
fi

echo "==> Building template $TAG from scratch"
[ -n "$MIRROR" ] && echo "    Debian mirror: $MIRROR"
[ -n "$SECURITY_MIRROR" ] && echo "    Debian security mirror: $SECURITY_MIRROR"

# --pull and --no-cache: a refresh is for taking updates, so nothing is reused.
# The build context holds nothing but the ImageMagick AppImage, when given.
CONTEXT="$(mktemp -d)"
trap 'rm -rf "$CONTEXT"' EXIT
if [ -n "$IMAGEMAGICK" ]; then
    [ -f "$IMAGEMAGICK" ] || { echo "ERROR: --imagemagick: no such file: $IMAGEMAGICK" >&2; exit 1; }
    echo "    ImageMagick from: $IMAGEMAGICK"
    cp "$IMAGEMAGICK" "$CONTEXT/magick.AppImage"
fi
docker build --pull --no-cache \
    --build-arg "DEBIAN_MIRROR=$MIRROR" \
    --build-arg "DEBIAN_SECURITY_MIRROR=$SECURITY_MIRROR" \
    -f Dockerfile.base -t "$TAG" "$CONTEXT"

echo "==> Template $TAG built:"
docker run --rm "$TAG" sed -n '1,6s/^/    /p' /etc/server_hosting_base.txt
echo "    (full package list: docker run --rm $TAG cat /etc/server_hosting_base.txt)"
