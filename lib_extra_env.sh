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
#   array EXTRA_NAMES. Exits non-zero if a referenced pass key is missing.
resolve_extra_env() {
    local arr_name="$1"
    EXTRA_NAMES=()
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
        else
            export "$name=$spec"
        fi
        EXTRA_NAMES+=("$name")
    done
}

# write_extra_env_override <override-path> [name ...]
#   Writes a docker-compose override that adds the given variable NAMES (only —
#   never their values) to the server service environment in list form, so
#   compose forwards each value from the process env at `up` time. With no
#   names, removes any stale override file.
write_extra_env_override() {
    local path="$1"
    shift
    if [ "$#" -eq 0 ]; then
        rm -f "$path"
        return 0
    fi
    {
        echo "services:"
        echo "  server:"
        echo "    environment:"
        local n
        for n in "$@"; do
            echo "      - $n"
        done
    } >"$path"
    chmod 600 "$path"
}
