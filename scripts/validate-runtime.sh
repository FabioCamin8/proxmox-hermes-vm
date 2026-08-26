#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

usage() {
    printf '%s\n' 'Usage: validate-runtime.sh [--env ENV_FILE]'
}

env_file=
while (($# > 0)); do
    case $1 in
        --env)
            (($# >= 2)) || die '--env requires a file'
            env_file=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -n "$env_file" ]]; then
    load_env "$env_file"
fi

HERMES_USER=${HERMES_USER:-hermes}
ADMIN_USER=${ADMIN_USER:-ops}
EXPECTED_HOSTNAME=${EXPECTED_HOSTNAME:-$(hostname -s)}
EXPECTED_MTU=${EXPECTED_MTU:-}
REQUIRE_AUTOLOGIN=${REQUIRE_AUTOLOGIN:-true}

[[ "$(id -un)" == "$ADMIN_USER" ]] \
    || die "run this validator from a fresh $ADMIN_USER SSH session"
command -v sudo >/dev/null 2>&1 || die 'sudo is unavailable'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

run_check() {
    local output=$1
    shift
    if "$@" >"$output" 2>&1; then
        return 0
    else
        local status=$?
        return "$status"
    fi
}

base_status=0
run_check "$tmp_dir/base" env \
    EXPECTED_USER="$ADMIN_USER" \
    EXPECTED_HOSTNAME="$EXPECTED_HOSTNAME" \
    EXPECTED_MTU="$EXPECTED_MTU" \
    "$script_dir/validate-guest.sh" || base_status=$?

security_status=0
if [[ -n "$env_file" ]]; then
    run_check "$tmp_dir/security" sudo -n "$script_dir/validate-hardening.sh" --env "$env_file" \
        || security_status=$?
else
    run_check "$tmp_dir/security" sudo -n "$script_dir/validate-hardening.sh" \
        || security_status=$?
fi

desktop_status=0
run_check "$tmp_dir/desktop" sudo -n -u "$HERMES_USER" env \
    HERMES_USER="$HERMES_USER" \
    REQUIRE_AUTOLOGIN="$REQUIRE_AUTOLOGIN" \
    "$script_dir/validate-desktop.sh" || desktop_status=$?

hermes_status=0
run_check "$tmp_dir/hermes" sudo -n -u "$HERMES_USER" env \
    HERMES_USER="$HERMES_USER" \
    "$script_dir/validate-hermes.sh" || hermes_status=$?

status_word() {
    [[ $1 -eq 0 ]] && printf PASS || printf FAIL
}

provider_state=$(sed -n 's/^provider=//p' "$tmp_dir/hermes" | tail -n 1)
[[ -n "$provider_state" ]] || provider_state=FAIL
gateway_state=$(sed -n 's/^gateway=//p' "$tmp_dir/security" | tail -n 1)
[[ -n "$gateway_state" ]] || gateway_state=FAIL

cua_status=1
if [[ $hermes_status -eq 0 ]] && grep -Fxq 'computer_use_doctor=exit-0' "$tmp_dir/hermes"; then
    cua_status=0
fi

overall_status=0
for check_status in "$base_status" "$security_status" "$desktop_status" "$hermes_status" "$cua_status"; do
    ((check_status == 0)) || overall_status=1
done
[[ "$provider_state" == PASS || "$provider_state" == NOT_CONFIGURED ]] || overall_status=1
[[ "$gateway_state" == PASS || "$gateway_state" == NOT_CONFIGURED ]] || overall_status=1

printf '%s\n' \
    "BASE        $(status_word "$base_status")" \
    "SECURITY    $(status_word "$security_status")" \
    "DESKTOP     $(status_word "$desktop_status")" \
    "HERMES      $(status_word "$hermes_status")" \
    "BROWSER     $(status_word "$desktop_status")" \
    "CUA         $(status_word "$cua_status")" \
    "PROVIDER    $provider_state" \
    "GATEWAY     $gateway_state"

if [[ $overall_status -eq 0 ]]; then
    printf '%s\n' 'RUNTIME READY'
    exit 0
fi

printf '%s\n' 'RUNTIME NOT READY' >&2
for check in base security desktop hermes; do
    check_status_var=${check}_status
    if (( ${!check_status_var} != 0 )); then
        printf '%s\n' "--- $check validation output ---" >&2
        sed -n '1,120p' "$tmp_dir/$check" >&2
    fi
done
if ((cua_status != 0)); then
    printf '%s\n' '--- CUA validation output ---' >&2
    sed -n '1,120p' "$tmp_dir/hermes" >&2
fi
exit 1
