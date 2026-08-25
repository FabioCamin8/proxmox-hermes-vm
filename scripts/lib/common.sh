#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

load_env() {
    local env_file=${1:?environment file is required}

    [[ -r "$env_file" ]] || die "environment file is not readable: $env_file"
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
}

require_var() {
    local name=$1
    [[ -n "${!name:-}" ]] || die "$name is required"
}

require_integer() {
    local name=$1
    local value=${!name:-}

    [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
}
