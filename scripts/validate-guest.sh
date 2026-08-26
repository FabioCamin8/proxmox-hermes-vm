#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

expected_hostname=${EXPECTED_HOSTNAME:-hermes-agent}
expected_user=${EXPECTED_USER:-hermes}
expected_mtu=${EXPECTED_MTU:-}

for command_name in cloud-init hostname ip systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || die "required guest command is unavailable: $command_name"
done

actual_hostname=$(hostname -s)
[[ "$actual_hostname" == "$expected_hostname" ]] || die "hostname mismatch: expected $expected_hostname, got $actual_hostname"
grep -Eq '^VERSION_ID="?13' /etc/os-release || die "guest is not Debian 13"

cloud_init_exit=0
if cloud_init_status=$(cloud-init status --long); then
    cloud_init_exit=0
else
    cloud_init_exit=$?
fi
printf '%s\n' "$cloud_init_status"
((cloud_init_exit == 0 || cloud_init_exit == 2)) \
    || die "Cloud-Init status command failed with exit $cloud_init_exit"
grep -q '^status: done$' <<<"$cloud_init_status" || die "Cloud-Init did not report done"
grep -q '^errors: \[\]$' <<<"$cloud_init_status" || die "Cloud-Init reported errors"

[[ "$(id -un)" == "$expected_user" ]] || die "run this validator as $expected_user"
id -nG | grep -qw sudo || die "$expected_user does not have the sudo group"

default_route=$(ip route show default)
[[ -n "$default_route" ]] || die "no default route is configured"
ip -br addr
printf '%s\n' "$default_route"

interface=$(ip -o link show | awk -F': ' '$2 !~ /^lo([:@]|$)/ { print $2; exit }')
[[ -n "$interface" ]] || die "no non-loopback interface found"
actual_mtu=$(ip -o link show dev "$interface" | awk '{ for (i = 1; i <= NF; i++) if ($i == "mtu") { print $(i + 1); exit } }')
[[ "$actual_mtu" =~ ^[0-9]+$ ]] || die "could not determine guest MTU"
if [[ -n "$expected_mtu" && "$actual_mtu" != "$expected_mtu" ]]; then
    die "MTU mismatch: expected $expected_mtu, got $actual_mtu"
fi
printf 'interface=%s mtu=%s\n' "$interface" "$actual_mtu"

systemctl is-active --quiet ssh || die "SSH service is not active"

if command -v sudo >/dev/null 2>&1; then
    sudo -n sshd -t || die "sshd configuration is invalid"
    sudo -n sshd -T | grep -Ei '^(pubkeyauthentication|passwordauthentication|permitrootlogin) '
fi

failed_units=$(systemctl --failed --no-legend)
if [[ -n "$failed_units" ]]; then
    printf '%s\n' "$failed_units" >&2
    die "systemd has failed units"
fi

if systemctl is-active --quiet qemu-guest-agent; then
    printf '%s\n' 'qemu-guest-agent=active'
else
    printf '%s\n' 'qemu-guest-agent=not-active (informational)'
fi

printf '%s\n' 'Guest validation passed.'
