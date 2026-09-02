#!/usr/bin/env bash
#
# setup-conf.sh — generate and maintain a deployment's host conf.
#
# Generic: this file names no product and holds no defaults. It knows the SHAPE
# of a conf — which variables must exist, which are per-environment — because
# that is this repo's contract with a server repo. It knows none of their
# values and never invents one. Every default comes from the product defaults
# file passed in with --defaults; a required value missing from there is a hard
# error naming the variable, not an empty string and not a guess.
#
# That split is the point. A default living in this repo would be a product
# decision made in a product-agnostic place, and the first time it was wrong for
# a second product nobody would notice.
#
# Usage:
#   setup-conf.sh --defaults FILE --dir DIR [--upgrade] [--yes]
#
#   --defaults FILE  the product defaults file (required)
#   --dir DIR        the deployment directory (required)
#   --upgrade        reconfigure now regardless of version
#   --yes            take every default; ask nothing (scripted installs)
#
# Modes, chosen by comparing the conf's stamped version against the server's:
#
#   no conf yet          -> install: ask, then write.
#   same major.minor     -> nothing to do. The conf already has every setting
#                           this server version knows about; refresh the code
#                           with `just deploy <env>`.
#   major/minor differs  -> upgrade: ask again, defaulting to the current
#                           answers, and ask about settings added since.
#
# The conf is owned outright by this script and rewritten wholesale on every
# run that writes. Nothing in it is meant to be hand-edited. What survives an
# upgrade is not the file but the ANSWERS: the existing conf is sourced first,
# so each value becomes the default for the prompt that regenerates it.

set -euo pipefail

DEFAULTS_FILE=""
DIR=""
FORCE_UPGRADE=0
ASSUME_YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --defaults)   shift; DEFAULTS_FILE="${1:-}" ;;
        --defaults=*) DEFAULTS_FILE="${1#*=}" ;;
        --dir)        shift; DIR="${1:-}" ;;
        --dir=*)      DIR="${1#*=}" ;;
        --upgrade)    FORCE_UPGRADE=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        -h|--help)    sed -n '3,40p' "$0"; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; exit 2 ;;
    esac
    shift || true
done

[ -n "$DEFAULTS_FILE" ] || { echo "ERROR: --defaults is required" >&2; exit 2; }
[ -f "$DEFAULTS_FILE" ] || { echo "ERROR: no such defaults file: $DEFAULTS_FILE" >&2; exit 2; }
[ -n "$DIR" ] || { echo "ERROR: --dir is required" >&2; exit 2; }

mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"

# ── The product defaults ────────────────────────────────────────────────────
# shellcheck disable=SC1090
source "$DEFAULTS_FILE"

# Everything below is required OF THE PRODUCT FILE. No fallbacks: a missing
# declaration is the product's bug, and a default invented here would hide it.
MISSING_DECL=()
for v in PRODUCT_CONF_NAME PRODUCT_PROJECT PRODUCT_GIT_URL PRODUCT_PASS_PREFIX PRODUCT_DEFAULT_ENVS; do
    [ -n "${!v:-}" ] || MISSING_DECL+=("$v")
done
declare -p PRODUCT_ENVS >/dev/null 2>&1 && [ ${#PRODUCT_ENVS[@]} -gt 0 ] || MISSING_DECL+=("PRODUCT_ENVS")
if [ ${#MISSING_DECL[@]} -gt 0 ]; then
    echo "ERROR: $DEFAULTS_FILE does not declare:" >&2
    printf '  - %s\n' "${MISSING_DECL[@]}" >&2
    exit 1
fi

CONF="$DIR/$PRODUCT_CONF_NAME"

# ── Prompting ───────────────────────────────────────────────────────────────
tty_ok() { { true >/dev/tty; } 2>/dev/null; }

ask() {  # ask VAR "Prompt" — the current value of VAR is the default
    local var="$1" prompt="$2" def="${!1:-}"
    if [ "$ASSUME_YES" != 1 ] && tty_ok; then
        printf '%s [%s]: ' "$prompt" "$def" > /dev/tty
        local ans=""; read -r ans < /dev/tty || true
        printf -v "$var" '%s' "${ans:-$def}"
    else
        printf -v "$var" '%s' "$def"
    fi
}

# ── The server's config-schema version ──────────────────────────────────────
# Fetched, never assumed. A failed fetch that fell through to "no upgrade
# needed" would reproduce exactly the silence this mechanism exists to remove,
# so it is fatal.
fetch_server_version() {
    local url="$1" ref="${2:-main}" owner_repo token api out
    owner_repo="$(printf '%s' "$url" | sed -E 's#^https?://github\.com/##; s#\.git$##')"
    case "$owner_repo" in
        */*) ;;
        *) echo "ERROR: cannot read owner/repo from GIT_URL: $url" >&2; return 1 ;;
    esac
    api="https://api.github.com/repos/${owner_repo}/contents/VERSION?ref=${ref}"
    token="$(pass show "${PRODUCT_PASS_PREFIX}/github-token" 2>/dev/null | head -1 || true)"
    if [ -n "$token" ]; then
        out="$(curl -fsSL -H "Authorization: Bearer $token" \
                    -H "Accept: application/vnd.github.raw" "$api" 2>/dev/null || true)"
    else
        out="$(curl -fsSL -H "Accept: application/vnd.github.raw" "$api" 2>/dev/null || true)"
    fi
    out="$(printf '%s' "$out" | tr -d '[:space:]')"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

vminor() { printf '%s' "$1" | cut -d. -f1-2; }

# Test seam: a file named by SETUP_CONF_TEST_HOOK is sourced here, so the
# version fetch can be stubbed without network or a token.
# shellcheck disable=SC1090
[ -n "${SETUP_CONF_TEST_HOOK:-}" ] && [ -f "$SETUP_CONF_TEST_HOOK" ] && source "$SETUP_CONF_TEST_HOOK"

# ── Resolving the answers ───────────────────────────────────────────────────
# Two things are decided per machine: which environments this host serves, and
# the port for each. Everything else is a product value written straight
# through.
#
# ASK=0 resolves them silently, from the existing conf where it has a value and
# from the product defaults otherwise. That is what makes a content comparison
# possible: render what THIS run would write, without asking anybody anything,
# and see whether it differs from the conf on disk.
declare -A OLD_PORT
resolve_answers() {
    local ask_them="$1" e k pv dv known

    # On a re-run the current conf is the default; on a fresh install the
    # product says which environments a new host serves. Not defaulted here:
    # "dev" would be a product decision made in a product-agnostic place, which
    # is the one thing this file must not do.
    if declare -p ENVS >/dev/null 2>&1; then
        SELECTED_ENVS="${ENVS[*]}"
    else
        SELECTED_ENVS="${PRODUCT_DEFAULT_ENVS:-}"
    fi
    if [ "$ask_them" = 1 ]; then
        echo
        ask SELECTED_ENVS "Which environments does this host serve? (${PRODUCT_ENVS[*]})"
    fi

    CHOSEN=()
    for e in $SELECTED_ENVS; do
        known=0
        for k in "${PRODUCT_ENVS[@]}"; do [ "$e" = "$k" ] && known=1; done
        [ "$known" = 1 ] || { echo "ERROR: '$e' is not an environment this product defines (${PRODUCT_ENVS[*]})" >&2; exit 1; }
        CHOSEN+=("$e")
    done
    [ ${#CHOSEN[@]} -gt 0 ] || { echo "ERROR: no environments selected" >&2; exit 1; }

    # The port is a product decision — the allocation is kept disjoint so
    # products cannot collide — but still asked, because this machine may
    # already have something on that port.
    for e in "${CHOSEN[@]}"; do
        pv="${e}_PORT"
        OLD_PORT[$e]="${!pv:-}"
        dv="PRODUCT_${e}_PORT"
        [ -n "${!pv:-}" ] || printf -v "$pv" '%s' "${!dv:-}"
        [ -n "${!pv:-}" ] || { echo "ERROR: $DEFAULTS_FILE declares no PRODUCT_${e}_PORT" >&2; exit 1; }
        [ "$ask_them" = 1 ] && ask "$pv" "Port for $e"
    done
    return 0
}


# ── Rendering the conf ──────────────────────────────────────────────────────
# A function so the same text can be rendered to a scratch file and COMPARED
# against the conf on disk. Version routing catches a new setting; only a
# content comparison catches a product value that changed.
render_conf() {
{
    echo "# Generated by setup-conf.sh. Do not hand-edit: this file is owned by"
    echo "# the installer and rewritten in full on every reconfigure. To change"
    echo "# something, re-run the installer with --upgrade; your current answers"
    echo "# become the defaults, so you only change what you mean to."
    echo "#"
    echo "# Product values come from the product defaults file, not from here."
    echo
    echo "# Config-schema version of the server this conf was written for."
    echo "# The installer compares it against the server's VERSION to decide"
    echo "# whether a re-run must ask about settings added since."
    echo "CONF_SCHEMA_VERSION=\"$TARGET_VERSION\""
    echo
    echo "PROJECT=\"$PRODUCT_PROJECT\""
    echo "GIT_URL=\"$PRODUCT_GIT_URL\""
    echo "PASS_PREFIX=\"$PRODUCT_PASS_PREFIX\""
    [ -n "${PRODUCT_STACK_PREFIX:-}" ] && echo "STACK_PREFIX=\"$PRODUCT_STACK_PREFIX\""
    [ -n "${PRODUCT_NGINX_CLIENT_MAX_BODY_SIZE:-}" ] && \
        echo "NGINX_CLIENT_MAX_BODY_SIZE=\"$PRODUCT_NGINX_CLIENT_MAX_BODY_SIZE\""
    echo
    echo "# Only the environments this host serves. An environment absent here"
    echo "# cannot be deployed from this machine, which is the point."
    echo "ENVS=(${CHOSEN[*]})"
    echo
    for e in "${CHOSEN[@]}"; do
        pv="${e}_PORT"; bv="PRODUCT_${e}_GIT_BRANCH"; wv="PRODUCT_${e}_ALLOWED_WEBSITES"
        echo "${e}_GIT_BRANCH=\"${!bv}\""
        echo "${e}_PORT=\"${!pv}\""
        [ -n "${!wv:-}" ] && echo "${e}_ALLOWED_WEBSITES=\"${!wv}\""
        echo
    done
    if declare -p PRODUCT_ENV_COMMON >/dev/null 2>&1 && [ ${#PRODUCT_ENV_COMMON[@]} -gt 0 ]; then
        echo "# Product identity and feature flags. Values that start with '@' are"
        echo "# read from pass and mounted as secret files; the rest are literals"
        echo "# passed as environment variables."
        echo "_COMMON_ENV=("
        for entry in "${PRODUCT_ENV_COMMON[@]}"; do
            [ -n "$entry" ] && echo "    \"$entry\""
        done
        echo ")"
        echo
    fi
    for e in "${CHOSEN[@]}"; do
        echo "${e}_EXTRA_ENV=(\"\${_COMMON_ENV[@]}\""
        # Templated per environment — an encryption KEK is one per environment
        # and never shared, so @ENV@ expands to the environment name.
        for tmpl in ${PRODUCT_ENV_PER_ENV[@]+"${PRODUCT_ENV_PER_ENV[@]}"}; do
            [ -n "$tmpl" ] || continue
            echo "    \"${tmpl//@ENV@/$e}\""
        done
        # Entries this product declares for THIS environment only — e.g. real
        # email delivery in prod and beta but not dev.
        only_var="PRODUCT_ENV_${e}_ONLY[@]"
        for entry in ${!only_var+"${!only_var}"}; do
            [ -n "$entry" ] && echo "    \"$entry\""
        done
        echo ")"
    done
} > "$1"
}

# ── Route: install, nothing-to-do, or upgrade ───────────────────────────────
MODE=install
INSTALLED_VERSION=""
if [ -f "$CONF" ]; then
    # Source the existing conf so every prior answer becomes this run's default.
    # This is what closes the gap in both directions: a value the operator
    # already chose comes back as its own default, and a value the product file
    # gained since falls through to the product default and becomes a new
    # question.
    # shellcheck disable=SC1090
    source "$CONF"
    INSTALLED_VERSION="${CONF_SCHEMA_VERSION:-0.0.0}"
    MODE=upgrade
fi

echo "==> Reading the server's config-schema version"
TARGET_VERSION="$(fetch_server_version "$PRODUCT_GIT_URL" "${PRODUCT_VERSION_REF:-main}")" || {
    echo "ERROR: could not read VERSION from $PRODUCT_GIT_URL" >&2
    echo "       The version decides whether this run must ask you about new" >&2
    echo "       settings, so a failed read is not something to guess past." >&2
    echo "       Check network access, and that ${PRODUCT_PASS_PREFIX}/github-token" >&2
    echo "       is present and still valid for a private repo." >&2
    exit 1
}
echo "    server=$TARGET_VERSION${INSTALLED_VERSION:+  conf=$INSTALLED_VERSION}"

ASK_QUESTIONS=1
if [ "$MODE" = upgrade ] && [ "$FORCE_UPGRADE" != 1 ]; then
    if [ "$(vminor "$INSTALLED_VERSION")" = "$(vminor "$TARGET_VERSION")" ]; then
        # The schema has not moved, so there is no new setting to ask about.
        # That is NOT the same as there being nothing to do: a product value
        # may have changed — a corrected sender address, a flipped feature
        # flag, a moved branch — and comparing versions is blind to it.
        #
        # So render what this run would write, using the answers already in the
        # conf and asking nothing, and compare it against the conf on disk.
        resolve_answers 0
        CANDIDATE="$(mktemp)"
        trap 'rm -f "$CANDIDATE"' EXIT
        render_conf "$CANDIDATE"

        if diff -q "$CONF" "$CANDIDATE" >/dev/null 2>&1; then
            cat <<EOF

    Nothing to configure. The conf already matches the product defaults, and
    the schema has not moved ($INSTALLED_VERSION -> $TARGET_VERSION is a patch).

    Refresh the code:   cd $DIR && just deploy <env>
    Reconfigure anyway: re-run with --upgrade

EOF
            exit 0
        fi

        # Product values drifted. These are never asked — they are written
        # straight through from the product defaults — so there is nothing to
        # prompt for. Rewrite, and say exactly what moved.
        echo
        echo "==> Product values changed since this conf was written:"
        # `diff` exits 1 when files differ and `grep` exits 1 on no match, both
        # of which are normal here; under `set -e` with `pipefail` either would
        # kill the script mid-report. This must not be one of those.
        diff -u "$CONF" "$CANDIDATE" \
            | grep -E '^[-+][^-+]' \
            | sed -e 's/^-/    was: /' -e 's/^+/    now: /' || true
        echo
        echo "    Rewriting the conf. A running container keeps the old values"
        echo "    until it is restarted: cd $DIR && just restart <env>"
        echo
        ASK_QUESTIONS=0
    else
        echo "    schema changed — reconfiguring"
    fi
fi

resolve_answers "$ASK_QUESTIONS"

# ── Everything required must be present before anything is written ──────────
# An unfilled product value is not a prompt. A sender address left at
# REPLACE_ME is a decision nobody has made yet, and the operator at the
# keyboard does not know it either — asking only invites an invented value. It
# belongs in the product defaults, filled when that installer is released.
UNSET_VALUES=()
for entry in ${PRODUCT_ENV_COMMON[@]+"${PRODUCT_ENV_COMMON[@]}"}; do
    [ -n "$entry" ] || continue
    name="${entry%%=*}"; val="${entry#*=}"
    [ "$val" = "REPLACE_ME" ] && UNSET_VALUES+=("$name")
done
for e in "${CHOSEN[@]}"; do
    for v in "PRODUCT_${e}_GIT_BRANCH"; do
        [ -n "${!v:-}" ] || UNSET_VALUES+=("$v")
    done
done
if [ ${#UNSET_VALUES[@]} -gt 0 ]; then
    echo >&2
    echo "ERROR: product values are unset and must be filled in $DEFAULTS_FILE:" >&2
    printf '  - %s\n' "${UNSET_VALUES[@]}" >&2
    echo >&2
    echo "These are product decisions, not host settings. Fill them in the" >&2
    echo "installer and release it; do not answer them here." >&2
    exit 1
fi

# ── Summary and confirm ─────────────────────────────────────────────────────
cat <<EOF

    product      $PRODUCT_PROJECT
    conf         $CONF
    schema       ${INSTALLED_VERSION:-(new)} -> $TARGET_VERSION
    environments ${CHOSEN[*]}
EOF
for e in "${CHOSEN[@]}"; do
    pv="${e}_PORT"; bv="PRODUCT_${e}_GIT_BRANCH"; wv="PRODUCT_${e}_ALLOWED_WEBSITES"
    printf '      %-5s port=%s branch=%s%s\n' "$e" "${!pv}" "${!bv}" \
        "$([ -n "${!wv:-}" ] && printf ' sites=%s' "${!wv}")"
done
echo
if [ "$ASSUME_YES" != 1 ] && tty_ok; then
    printf 'Proceed? [Y/n]: ' > /dev/tty
    read -r go < /dev/tty || true
    case "${go:-Y}" in [nN]*) echo "Aborted."; exit 1 ;; esac
fi

# ── Changing a port under a live vhost must be loud ─────────────────────────
# There is no re-install recipe: setup-nginx.sh refuses a second run because
# certbot rewrites the vhost in place, and a rerun would drop a live site back
# to plain HTTP. So a changed port leaves nginx proxying to the old one.
for e in "${CHOSEN[@]}"; do
    pv="${e}_PORT"; old="${OLD_PORT[$e]:-}"
    if [ -n "$old" ] && [ "$old" != "${!pv}" ]; then
        wv="PRODUCT_${e}_ALLOWED_WEBSITES"
        if [ -n "${!wv:-}" ]; then
            domain="${!wv%%,*}"
            echo
            echo "!! ${e}_PORT changed $old -> ${!pv}. The nginx vhost for $domain"
            echo "   still proxies to $old. Re-run the installer's --install-ngx step"
            echo "   for $e, with --force."
            echo
        fi
    fi
done

# ── Write the conf, wholesale ───────────────────────────────────────────────
echo "==> Writing $CONF"
render_conf "$CONF"
chmod 600 "$CONF"

# ── The deployment justfile ─────────────────────────────────────────────────
echo "==> Writing $DIR/justfile"
cat > "$DIR/justfile" <<JUST_EOF
export SCRIPTS := justfile_directory() / "server_hosting_scripts"
export CONF := justfile_directory() / "$PRODUCT_CONF_NAME"
export BACKUP_DIR := justfile_directory() / "backup"

import 'server_hosting_scripts/justfile'
JUST_EOF

mkdir -p "$DIR/backup"
[ -f "$DIR/backup/.keep" ] || touch "$DIR/backup/.keep"

cat <<EOF

==> $([ "$MODE" = upgrade ] && echo "Reconfigured" || echo "Configured") $DIR

    conf    $CONF   (schema $TARGET_VERSION)
    envs    ${CHOSEN[*]}

Next:
    cd $DIR
    just deploy ${CHOSEN[0]}
EOF
