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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── The environments ────────────────────────────────────────────────────────
# Fixed here, not chosen by a product. These names carry tooling semantics:
# `dev` is the only environment allowed to track a commit rather than a branch,
# and the only one exposed beyond localhost (deploy-conf.sh enforces both). A
# product that invented its own set would silently lose that handling, so a
# product picks VALUES for these environments, never the set itself.
KNOWN_ENVS=(prod beta dev)

# What each environment is called when a person is asked about it. Prompts only:
# the conf, the container names and every script keep the short forms.
declare -A ENV_LABEL=([prod]=PRODUCTION [beta]=BETA [dev]=DEVELOPMENT)

env_labels() {  # env_labels "prod dev" -> "PRODUCTION DEVELOPMENT"
    local out=() e
    for e in $1; do out+=("${ENV_LABEL[$e]:-$e}"); done
    printf '%s' "${out[*]}"
}

# Exact match on the long name, case and all. Not a nicety withheld: typing
# PRODUCTION in full is the moment to notice you did not mean to, and accepting
# "prod" or "Dev" would let the most consequential answer in the run be given by
# reflex.
env_from_label() {
    local e
    for e in "${KNOWN_ENVS[@]}"; do
        [ "$1" = "${ENV_LABEL[$e]}" ] && { printf '%s' "$e"; return 0; }
    done
    return 1
}

# What a fresh host serves when it has no conf yet. A new install is somebody's
# dev box far more often than it is a production one, and defaulting to prod
# would make the wrong accident easy.
DEFAULT_ENVS="dev"

# ── The product config ──────────────────────────────────────────────────────
# Plain INI, parsed here. It is data, not code: a product cannot run anything,
# shadow a function, or set a variable this script relies on — which a sourced
# bash file could all do by accident.
#
# Sections:
#   [product]           identity
#   [tooling]           which server_hosting_scripts build, and the version ref
#   [env.<name>]        branch / port / websites for one environment
#   [server_env]        env passthrough for every environment
#   [server_env.<name>] env passthrough for one environment only
#
# In a passthrough value, {env} expands to the environment name and a leading @
# means "read from pass" — which the deploy tooling already treats as the signal
# to mount it as a secret file rather than an environment variable.
declare -A PC          # "section.key" -> value
declare -A PC_KEYS     # "section"     -> space-separated keys, in file order

parse_product_conf() {
    local file="$1" section="" line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            ''|'#'*|';'*) continue ;;
            '['*']')
                section="${line#[}"; section="${section%]}"
                continue ;;
        esac
        [ -n "$section" ] || { echo "ERROR: $file: '$line' appears before any [section]" >&2; exit 1; }
        case "$line" in
            *=*) ;;
            *) echo "ERROR: $file: no '=' in line: $line" >&2; exit 1 ;;
        esac
        key="${line%%=*}"; value="${line#*=}"
        # trim surrounding whitespace from both halves
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
        PC["$section.$key"]="$value"
        PC_KEYS["$section"]="${PC_KEYS["$section"]:-}${PC_KEYS["$section"]:+ }$key"
    done < "$file"
}

# env_ref <env> — what that environment deploys. dev says `ref`, the rest `branch`.
env_ref() {
    if [ "$1" = dev ]; then pc "env.$1" ref; else pc "env.$1" branch; fi
}

# Everything in the config is lowercase. These are the keys the installer reads
# for itself; anything else in a section is passed to the server, upper-cased,
# because that is what an environment variable looks like — a translation the
# config should not have to carry.
INSTALLER_KEYS=" company_id project git_url pass_prefix branch ref port websites "
is_server_key() { case "$INSTALLER_KEYS" in *" $1 "*) return 1 ;; *) return 0 ;; esac; }
env_name() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# A pass path is relative to pass_prefix, which is why pass_prefix exists.
# Leading slash means absolute, for a secret kept outside the product's tree.
pass_path() {
    case "$1" in
        @/*) printf '@%s' "${1#@/}" ;;
        @*)  printf '@%s/%s' "$PRODUCT_PASS_PREFIX" "${1#@}" ;;
        *)   printf '%s' "$1" ;;
    esac
}

# pc <section> <key> [default] — a missing key with no default is fatal, by name.
pc() {
    local k="$1.$2"
    if [ -n "${PC[$k]+x}" ]; then printf '%s' "${PC[$k]}"; return 0; fi
    if [ $# -ge 3 ]; then printf '%s' "$3"; return 0; fi
    echo "ERROR: $DEFAULTS_FILE does not set [$1] $2" >&2
    # Inside $( ), `exit` ends only the subshell; without this the caller would
    # carry on and write the empty value it just failed to produce.
    kill -TERM $$ 2>/dev/null
    exit 1
}

parse_product_conf "$DEFAULTS_FILE"

PRODUCT_PROJECT="$(pc product project)"
PRODUCT_GIT_URL="$(pc product git_url)"
PRODUCT_PASS_PREFIX="$(pc product pass_prefix)"
PRODUCT_STACK_PREFIX="$(pc product company_id '')"

# Derived, not declared: repeating them in every product config would be two
# more values to get wrong for no decision gained.
PRODUCT_CONF_NAME="host_${PRODUCT_PROJECT}_server.conf"

# Every environment must be fully described, so a host cannot select one that
# turns out to be half-configured.
for e in "${KNOWN_ENVS[@]}"; do
    # prod and beta must track a branch so they can move forward; only dev may
    # be pinned to a tag or a commit, so only dev takes a `ref`.
    if [ "$e" = dev ]; then
        [ -n "${PC[env.$e.ref]+x}" ] || { echo "ERROR: $DEFAULTS_FILE has no [env.$e] ref" >&2; exit 1; }
    else
        [ -n "${PC[env.$e.branch]+x}" ] || { echo "ERROR: $DEFAULTS_FILE has no [env.$e] branch" >&2; exit 1; }
        [ -n "${PC[env.$e.ref]+x}" ] && { echo "ERROR: [env.$e] uses 'ref'; only dev may be pinned to a tag or commit. Use 'branch'." >&2; exit 1; }
    fi
    [ -n "${PC[env.$e.port]+x}" ]   || { echo "ERROR: $DEFAULTS_FILE has no [env.$e] port" >&2; exit 1; }
done

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
    local ask_them="$1" e pv _v
    MAX_UPLOAD_MB="${MAX_UPLOAD_MB:-}"

    # On a re-run the current conf is the default; on a fresh install the
    # product says which environments a new host serves. Not defaulted here:
    # "dev" would be a product decision made in a product-agnostic place, which
    # is the one thing this file must not do.
    if declare -p ENVS >/dev/null 2>&1; then
        SELECTED_ENVS="${ENVS[*]}"
    else
        SELECTED_ENVS="$DEFAULT_ENVS"
    fi
    local _typed=0
    if [ "$ask_them" = 1 ] && [ "$ASSUME_YES" != 1 ] && { true >/dev/tty; } 2>/dev/null; then
        local _choices _default _answer
        _choices="$(env_labels "${KNOWN_ENVS[*]}")"; _choices="${_choices// / | }"
        _default="$(env_labels "$SELECTED_ENVS")"
        echo > /dev/tty
        printf '%s [%s]: ' "$_choices" "$_default" > /dev/tty
        read -r _answer < /dev/tty || true
        SELECTED_ENVS="${_answer:-$_default}"
        _typed=1
    fi

    # A typed answer is matched against the long names only. A value that was
    # not typed — carried over from an existing conf, or the fresh-install
    # default under --yes — is already an internal name and is checked as one.
    CHOSEN=()
    local k _valid
    for e in $SELECTED_ENVS; do
        if [ "$_typed" = 1 ]; then
            k="$(env_from_label "$e")" || {
                _valid="$(env_labels "${KNOWN_ENVS[*]}")"
                echo "ERROR: '$e' is not an environment. Type one of: ${_valid// / | }" >&2
                echo "       Exactly as shown, in capitals." >&2
                exit 1; }
        else
            k=""
            for _v in "${KNOWN_ENVS[@]}"; do [ "$e" = "$_v" ] && k="$e"; done
            [ -n "$k" ] || { echo "ERROR: '$e' is not an environment (${KNOWN_ENVS[*]})" >&2; exit 1; }
        fi
        CHOSEN+=("$k")
    done
    [ ${#CHOSEN[@]} -gt 0 ] || { echo "ERROR: no environments selected" >&2; exit 1; }

    # The port is a product decision — the allocation is kept disjoint so
    # products cannot collide — but still asked, because this machine may
    # already have something on that port.
    for e in "${CHOSEN[@]}"; do
        pv="${e}_PORT"
        OLD_PORT[$e]="${!pv:-}"
        [ -n "${!pv:-}" ] || printf -v "$pv" '%s' "$(pc "env.$e" port)"
        [ "$ask_them" = 1 ] && ask "$pv" "Port for ${ENV_LABEL[$e]:-$e}"   # ask() honours ASSUME_YES
    done

    # One number for both nginx and the server. The server's own default is 50
    # (a 50 MB video); nginx must not sit below whatever the server accepts, and
    # two numbers that can disagree is the failure this avoids.
    MAX_UPLOAD_MB="${MAX_UPLOAD_MB:-${NGINX_CLIENT_MAX_BODY_SIZE:-}}"; MAX_UPLOAD_MB="${MAX_UPLOAD_MB%M}"
    MAX_UPLOAD_MB="${MAX_UPLOAD_MB:-50}"
    if [ "$ask_them" = 1 ]; then
        ask MAX_UPLOAD_MB "Maximum upload size in MB"
        case "$MAX_UPLOAD_MB" in
            ''|*[!0-9]*) echo "ERROR: upload size must be a whole number of MB, got '$MAX_UPLOAD_MB'" >&2; exit 1 ;;
        esac
        if [ "$MAX_UPLOAD_MB" -lt 50 ]; then
            echo "    note: below the server's default of 50, so videos between"
            echo "          ${MAX_UPLOAD_MB}MB and 50MB will be refused."
        fi
    fi
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
    # nginx caps the whole request, which is the file plus its multipart
    # envelope, so it sits a little above the file limit the server enforces.
    # Equal numbers would 413 an upload of exactly the permitted size.
    echo "NGINX_CLIENT_MAX_BODY_SIZE=\"$((MAX_UPLOAD_MB + 5))M\""
    echo
    echo "# Only the environments this host serves. An environment absent here"
    echo "# cannot be deployed from this machine, which is the point."
    echo "ENVS=(${CHOSEN[*]})"
    echo
    for e in "${CHOSEN[@]}"; do
        pv="${e}_PORT"; _sites="$(pc "env.$e" websites '')"
        echo "${e}_GIT_BRANCH=\"$(pc "env.$e" ref)\""
        echo "${e}_PORT=\"${!pv}\""
        [ -n "$_sites" ] && echo "${e}_ALLOWED_WEBSITES=\"$_sites\""
        echo
    done
    echo "# Product identity, email settings and feature flags. A value starting"
    echo "# with '@' is read from pass and mounted as a secret file; the rest are"
    echo "# literals passed as environment variables."
    echo "_COMMON_ENV=("
    for sect in product email_service; do
        for k in ${PC_KEYS[$sect]:-}; do
            is_server_key "$k" || continue
            # {env} entries belong to one environment, so they go below.
            case "${PC[$sect.$k]}" in *'{env}'*) continue ;; esac
            echo "    \"$(env_name "$k")=$(pass_path "${PC[$sect.$k]}")\""
        done
    done
    # Set from one answer so nginx and the server cannot disagree about it.
    echo "    \"MAX_VIDEO_UPLOAD_SIZE_MB=$MAX_UPLOAD_MB\""
    echo ")"
    echo
    for e in "${CHOSEN[@]}"; do
        echo "${e}_EXTRA_ENV=(\"\${_COMMON_ENV[@]}\""
        # Entries carrying {env}: one per environment, never shared. An
        # encryption KEK is the reason this exists.
        for sect in product email_service; do
            for k in ${PC_KEYS[$sect]:-}; do
                is_server_key "$k" || continue
                case "${PC[$sect.$k]}" in
                    *'{env}'*) echo "    \"$(env_name "$k")=$(pass_path "${PC[$sect.$k]//\{env\}/$e}")\"" ;;
                esac
            done
        done
        # Declared for this environment only.
        for sect in "env.$e" "email_service.$e"; do
            for k in ${PC_KEYS[$sect]:-}; do
                is_server_key "$k" || continue
                echo "    \"$(env_name "$k")=$(pass_path "${PC[$sect.$k]//\{env\}/$e}")\""
            done
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

# Which environments this host serves, resolved without asking, so the version
# below can be read from the refs those environments actually deploy.
resolve_answers 0

# The version being installed is the server's own, at the ref each environment
# tracks — there is no separate setting for it. Environments can sit at
# different refs, so the highest wins: it is the one whose settings the conf has
# to be able to satisfy.
echo "==> Reading the server's config-schema version"
TARGET_VERSION=""
for e in "${CHOSEN[@]}"; do
    _ref="$(env_ref "$e")"
    _v="$(fetch_server_version "$PRODUCT_GIT_URL" "$_ref")" || {
        echo "ERROR: could not read VERSION from $PRODUCT_GIT_URL at '$_ref' (${ENV_LABEL[$e]:-$e})" >&2
        echo "       The version decides whether this run must ask you about new" >&2
        echo "       settings, so a failed read is not something to guess past." >&2
        echo "       Check network access, and that ${PRODUCT_PASS_PREFIX}/github-token" >&2
        echo "       is present and still valid for a private repo." >&2
        exit 1
    }
    echo "    ${ENV_LABEL[$e]:-$e} @ $_ref -> $_v"
    if [ -z "$TARGET_VERSION" ] || [ "$(printf '%s\n%s\n' "$TARGET_VERSION" "$_v" | sort -V | tail -1)" = "$_v" ]; then
        TARGET_VERSION="$_v"
    fi
done
[ -n "${INSTALLED_VERSION:-}" ] && echo "    conf was written for $INSTALLED_VERSION"

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
for sect in product email_service; do
    for name in ${PC_KEYS[$sect]:-}; do
        is_server_key "$name" || continue
        [ "${PC[$sect.$name]}" = "REPLACE_ME" ] && UNSET_VALUES+=("[$sect] $name")
    done
done
for e in "${CHOSEN[@]}"; do
    [ -n "$(env_ref "$e")" ] || UNSET_VALUES+=("[env.$e] branch")
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
    pv="${e}_PORT"; _sites="$(pc "env.$e" websites '')"
    printf '      %-5s port=%s branch=%s%s\n' "$e" "${!pv}" "$(env_ref "$e")" \
        "$([ -n "$_sites" ] && printf ' sites=%s' "$_sites")"
done
echo
if [ "$ASSUME_YES" != 1 ] && tty_ok; then
    printf 'Write this configuration? [Y/n]: ' > /dev/tty
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
        _sites="$(pc "env.$e" websites '')"
        if [ -n "$_sites" ]; then
            domain="${_sites%%,*}"
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
EOF

# Offer to deploy. Configuring writes files; deploying builds an image and
# starts containers, so it is asked per environment and never assumed. Under
# --yes nothing is deployed: a scripted run should not start a server as a side
# effect of being configured.
DEPLOYED=()
if [ "$ASSUME_YES" != 1 ] && tty_ok; then
    echo > /dev/tty
    for e in "${CHOSEN[@]}"; do
        printf 'Deploy %s now? [Y/n]: ' "${ENV_LABEL[$e]:-$e}" > /dev/tty
        read -r _go < /dev/tty || true
        case "${_go:-Y}" in
            [nN]*) ;;
            *) DEPLOYED+=("$e") ;;
        esac
    done
fi

for e in ${DEPLOYED[@]+"${DEPLOYED[@]}"}; do
    echo
    echo "==> Deploying ${ENV_LABEL[$e]:-$e}"
    ( cd "$DIR" && "$SCRIPT_DIR/deploy-conf.sh" "$CONF" "$e" )
done

# Whatever was not deployed is configured and nothing more. Say so: the gap
# between "the conf says X" and "the server does X" is exactly where a change
# gets believed before it has happened.
PENDING=()
for e in "${CHOSEN[@]}"; do
    _done=0
    for d in ${DEPLOYED[@]+"${DEPLOYED[@]}"}; do [ "$d" = "$e" ] && _done=1; done
    [ "$_done" = 1 ] || PENDING+=("$e")
done

if [ ${#PENDING[@]} -gt 0 ]; then
    echo
    _pending_labels="$(env_labels "${PENDING[*]}")"; _pending_labels="${_pending_labels// /, }"
    [ ${#PENDING[@]} -eq 1 ] && _verb=runs || _verb=run
    if [ "$MODE" = upgrade ]; then
        echo "!! NOT DEPLOYED — this configuration is not live."
        echo "   A server keeps the settings it started with, so $_pending_labels"
        echo "   $_verb the previous configuration until you apply it."
    else
        echo "!! NOT DEPLOYED — nothing is running yet for $_pending_labels."
    fi
    echo
    echo "   cd $DIR"
    for e in "${PENDING[@]}"; do
        if [ "$MODE" = upgrade ]; then
            # restart re-reads the conf and recreates the containers, so a
            # configuration-only change needs no rebuild.
            echo "   just restart $e     # apply this configuration to the running image"
            echo "   just deploy  $e     # rebuild from git, then apply"
        else
            echo "   just deploy $e"
        fi
    done
    echo
fi
