#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

[[ $(id -u) -eq 0 ]] || die 'run this script as root inside the guest'

HERMES_USER=${HERMES_USER:-hermes}
HERMES_INSTALLER_URL=${HERMES_INSTALLER_URL:-https://hermes-agent.nousresearch.com/install.sh}
HERMES_COMMIT=${HERMES_COMMIT:-}

[[ "$HERMES_USER" != root ]] || die 'HERMES_USER must be unprivileged'
getent passwd "$HERMES_USER" >/dev/null || die "user does not exist: $HERMES_USER"
command -v curl >/dev/null 2>&1 || die 'curl is unavailable'
command -v install >/dev/null 2>&1 || die 'install is unavailable'

if [[ -n "$HERMES_COMMIT" ]]; then
    [[ "$HERMES_COMMIT" =~ ^[0-9a-fA-F]{40}$ ]] || die 'HERMES_COMMIT must be a full 40-character Git SHA'
fi

user_home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
[[ -n "$user_home" && -d "$user_home" ]] || die "home directory is unavailable: $user_home"

installer_file=$(mktemp /tmp/hermes-agent-installer.XXXXXX.sh)
receipt_file=$(mktemp)
trap 'rm -f -- "$installer_file" "$receipt_file"' EXIT
chmod 0700 "$installer_file"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$HERMES_INSTALLER_URL" --output "$installer_file"
chown "$HERMES_USER:$HERMES_USER" "$installer_file"

grep -q -- '--skip-setup' "$installer_file" || die 'installer lacks the required --skip-setup option'
grep -q -- '--skip-browser' "$installer_file" || die 'installer browser controls changed; inspect before proceeding'
grep -q -- '--skip-computer-use' "$installer_file" \
    || die 'installer Computer Use controls changed; inspect before proceeding'

installer_sha256=$(sha256sum "$installer_file" | awk '{print $1}')
installer_args=(--skip-setup)
if [[ -n "$HERMES_COMMIT" ]]; then
    installer_args+=(--commit "$HERMES_COMMIT")
fi

sudo -n -u "$HERMES_USER" env \
    HOME="$user_home" \
    PATH="$user_home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
    bash "$installer_file" "${installer_args[@]}"

source_dir="$user_home/.hermes/hermes-agent"
[[ -d "$source_dir/.git" ]] || die 'Hermes source checkout was not created'
command -v git >/dev/null 2>&1 || die 'git is unavailable after the official installer'
source_commit=$(git -C "$source_dir" rev-parse HEAD)
hermes_version=$(sudo -n -u "$HERMES_USER" env HOME="$user_home" PATH="$user_home/.local/bin:/usr/local/bin:/usr/bin:/bin" hermes --version | head -n 1)

{
    printf 'installer_url=%s\n' "$HERMES_INSTALLER_URL"
    printf 'installer_sha256=%s\n' "$installer_sha256"
    printf 'requested_commit=%s\n' "${HERMES_COMMIT:-latest-main}"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'hermes_version=%s\n' "$hermes_version"
    printf 'install_user=%s\n' "$HERMES_USER"
    printf 'setup_skipped=true\n'
    printf 'browser_skip=false\n'
    printf 'computer_use_skip=false\n'
} >"$receipt_file"
install -D -o "$HERMES_USER" -g "$HERMES_USER" -m 0644 "$receipt_file" \
    "$user_home/.hermes/hermes-install-receipt"

printf '%s\n' \
    'Hermes bootstrap completed with the official installer.' \
    "user=$HERMES_USER" \
    "source_commit=$source_commit" \
    "version=$hermes_version" \
    "receipt=$user_home/.hermes/hermes-install-receipt"
