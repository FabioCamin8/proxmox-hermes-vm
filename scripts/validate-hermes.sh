#!/usr/bin/env bash

set -Eeuo pipefail

HERMES_USER=${HERMES_USER:-hermes}
[[ "$(id -un)" == "$HERMES_USER" ]] || {
    printf 'error: run this validator as %s\n' "$HERMES_USER" >&2
    exit 1
}

export PATH="$HOME/.local/bin:$PATH"
for command_name in hermes git node npm rg ffmpeg cua-driver; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'error: required Hermes command is unavailable: %s\n' "$command_name" >&2
        exit 1
    }
done

source_dir="$HOME/.hermes/hermes-agent"
[[ -d "$source_dir/.git" ]] || {
    printf '%s\n' 'error: Hermes managed source checkout is missing' >&2
    exit 1
}
[[ -x "$HOME/.hermes/hermes-agent/venv/bin/hermes" ]] || {
    printf '%s\n' 'error: Hermes managed virtual-environment entry point is missing' >&2
    exit 1
}

printf '%s\n' "hermes=$(command -v hermes)"
hermes --version
printf 'source_commit=%s\n' "$(git -C "$source_dir" rev-parse HEAD)"
printf 'source_status=%s\n' "$(git -C "$source_dir" status --short | tr '\n' ' ')"
printf 'node=%s\n' "$(node --version)"
printf 'npm=%s\n' "$(npm --version)"
printf 'rg=%s\n' "$(rg --version | head -n 1)"
printf 'ffmpeg=%s\n' "$(ffmpeg -version | head -n 1)"
printf 'cua_driver=%s\n' "$(cua-driver --version | head -n 1)"

hermes --help >/dev/null
doctor_output=$(mktemp)
trap 'rm -f -- "$doctor_output"' EXIT
doctor_status=0
if hermes doctor >"$doctor_output" 2>&1; then
    doctor_status=0
else
    doctor_status=$?
fi
cat "$doctor_output"
provider_state=PASS
if grep -Eiq '(provider|model|api[ -]?key|authentication|auth)' "$doctor_output" \
    && grep -Eiq '(not configured|not set|missing|no provider|setup|sign in|authenticate)' "$doctor_output"; then
    provider_state=NOT_CONFIGURED
fi
if ((doctor_status != 0)); then
    printf '%s\n' 'error: Hermes doctor reported a runtime failure' >&2
    exit "$doctor_status"
fi
printf '%s\n' 'hermes_doctor=exit-0'
hermes computer-use status
printf '%s\n' 'computer_use_status=exit-0'

if [[ -x "$HOME/.local/bin/hermes-graphical" && -r "$HOME/.config/hermes/graphical-session.env" ]]; then
    "$HOME/.local/bin/hermes-graphical" hermes computer-use doctor
    printf '%s\n' 'computer_use_doctor=exit-0'
else
    printf '%s\n' 'computer_use_doctor=NOT_TESTED (graphical session environment is unavailable)'
fi

if [[ -d "$HOME/.cache/ms-playwright" ]]; then
    printf '%s\n' 'playwright_browser_cache=present'
else
    printf '%s\n' 'playwright_browser_cache=NOT_TESTED (cache is absent)'
fi

printf '%s\n' \
    "provider=$provider_state" \
    'Hermes validation passed.'
