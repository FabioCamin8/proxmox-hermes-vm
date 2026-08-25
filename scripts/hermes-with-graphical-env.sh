#!/usr/bin/env bash

set -Eeuo pipefail

[[ $# -gt 0 ]] || {
    printf 'usage: %s COMMAND [ARG...]\n' "${0##*/}" >&2
    exit 2
}

env_file=${HERMES_GRAPHICAL_ENV_FILE:-$HOME/.config/hermes/graphical-session.env}
[[ -r "$env_file" ]] || {
    printf 'error: graphical session environment is unavailable: %s\n' "$env_file" >&2
    printf '%s\n' 'Log in to the XFCE session once, or run the session-start helper there.' >&2
    exit 1
}

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

export PATH="$HOME/.local/bin:$PATH"
exec "$@"
