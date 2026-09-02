#!/bin/bash
# Shared helpers for the optional, generic extra-env passthrough.
#
# This lets a host conf inject additional environment variables into the server
# container without this (generic) tooling knowing what they are for. Secret
# values flow through the process environment only — exactly like SECRET_KEY —
# and are never written to disk; only variable NAMES are written, into a
# compose override.

# resolve_extra_env <array-var-name>
#   Reads a bash array <array-var-name> whose entries are "NAME=spec". A spec
#   beginning with '@' is resolved from `pass` (the remainder is the pass key);
#   any other spec is a literal value. Each resolved value is exported into the
#   current process env, and the variable names are collected into the global
#   array EXTRA_NAMES, and additionally split into EXTRA_SECRET_NAMES (specs
#   that came from `pass`) and EXTRA_PLAIN_NAMES (literals). Exits non-zero if
#   a referenced pass key is missing.
#
#   The @-prefix already told us which values are secret, in order to validate
#   the store. That same split is the routing rule: a pass-sourced value becomes
#   a mounted secret file, a literal stays an environment variable. No new conf
#   syntax, and no conf migration.
resolve_extra_env() {
    local arr_name="$1"
    EXTRA_NAMES=()
    EXTRA_SECRET_NAMES=()
    EXTRA_PLAIN_NAMES=()
    declare -p "$arr_name" >/dev/null 2>&1 || return 0  # undefined → nothing to do

    local -n _entries="$arr_name"
    local entry name spec
    local missing=()

    for entry in "${_entries[@]}"; do
        spec="${entry#*=}"
        if [[ "$spec" == @* ]]; then
            pass show "${spec#@}" &>/dev/null || missing+=("${spec#@}")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing extra-env secrets in pass store:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi

    for entry in "${_entries[@]}"; do
        name="${entry%%=*}"
        spec="${entry#*=}"
        if [[ "$spec" == @* ]]; then
            export "$name=$(pass show "${spec#@}")"
            EXTRA_SECRET_NAMES+=("$name")
        else
            export "$name=$spec"
            EXTRA_PLAIN_NAMES+=("$name")
        fi
        EXTRA_NAMES+=("$name")
    done
}

# write_extra_env_override <override-path> <plain-names> <secret-names>
#   Writes a docker-compose override for the generic passthrough. Both name
#   lists are space-separated and may be empty.
#
#   Plain names become `environment:` entries in list form, so compose forwards
#   each value from the process env at `up` time — values are never written to
#   disk.
#
#   Secret names become compose secrets sourced from the same process env. The
#   container then sees a tmpfs file at /run/secrets/<lowercased name> and no
#   environment entry at all, so the value is absent from `docker inspect`,
#   from /proc/<pid>/environ and from the compose config dump. The file is
#   named in lowercase because pydantic-settings matches a secret file to a
#   settings field by name, and fields are lowercase.
#
#   With both lists empty, removes any stale override file.
write_extra_env_override() {
    local path="$1" plain="${2:-}" secret="${3:-}"
    if [ -z "$plain$secret" ]; then
        rm -f "$path"
        return 0
    fi
    local n
    {
        echo "services:"
        echo "  server:"
        if [ -n "$plain" ]; then
            echo "    environment:"
            for n in $plain; do
                echo "      - $n"
            done
        fi
        if [ -n "$secret" ]; then
            echo "    secrets:"
            for n in $secret; do
                echo "      - $(echo "$n" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"')"
            done
        fi
        if [ -n "$secret" ]; then
            echo "secrets:"
            for n in $secret; do
                echo "  $(echo "$n" | tr '"'"'[:upper:]'"'"' '"'"'[:lower:]'"'"'):"
                echo "    environment: $n"
            done
        fi
    } >"$path"
    chmod 600 "$path"
}
