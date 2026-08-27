#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

expected_hostname=${EXPECTED_HOSTNAME:-hermes-agent}
expected_user=${EXPECTED_USER:-hermes}
expected_mtu=${EXPECTED_MTU:-}

for command_name in cloud-init dpkg-query hostname ip modprobe sudo systemctl uname; do
    command -v "$command_name" >/dev/null 2>&1 || die "required guest command is unavailable: $command_name"
done

actual_hostname=$(hostname -s)
[[ "$actual_hostname" == "$expected_hostname" ]] || die "hostname mismatch: expected $expected_hostname, got $actual_hostname"
grep -Eq '^VERSION_ID="?13' /etc/os-release || die "guest is not Debian 13"

package_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == 'install ok installed' ]]
}

running_kernel=$(uname -r)
[[ "$running_kernel" != *-cloud-amd64 ]] \
    || die "the running kernel is still the Debian cloud kernel: $running_kernel"
package_installed linux-image-amd64 \
    || die 'linux-image-amd64 is not installed'
! package_installed linux-image-cloud-amd64 \
    || die 'linux-image-cloud-amd64 meta-package is still installed'
printf '%s\n' \
    "running_kernel=$running_kernel" \
    'linux-image-amd64=installed' \
    'linux-image-cloud-amd64=absent'

for module in usbhid xhci_pci; do
    sudo -n modprobe --dry-run "$module" \
        || die "kernel module is unavailable or not loadable: $module"
    printf 'kernel_module=%s loadable\n' "$module"
done

input_devices=/proc/bus/input/devices
[[ -r "$input_devices" ]] || die 'kernel input enumeration is unavailable'
grep -Eq 'QEMU( QEMU)? USB Tablet' "$input_devices" \
    || die 'QEMU USB Tablet is absent from kernel input enumeration'
printf '%s\n' 'qemu_usb_tablet=present in kernel input enumeration'

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
