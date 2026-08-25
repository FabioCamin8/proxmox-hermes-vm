#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

[[ $# -eq 1 ]] || die "usage: validate-pve.sh ENV_FILE"
load_env "$1"

for name in VMID STORAGE BRIDGE MACHINE BIOS; do
    require_var "$name"
done
require_integer VMID

for command_name in pveversion qm pvesm ip; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required Proxmox command is unavailable: $command_name"
done

printf '%s\n' 'PVE version:'
pveversion -v | grep -E '^(pve-manager|qemu-server|pve-qemu-kvm|proxmox-ve):' || true

qm help set >/dev/null 2>&1 || die "qm set is unavailable"
qm help cloudinit >/dev/null 2>&1 || die "qm cloudinit is unavailable"

pvesm status | awk -v storage="$STORAGE" '
    $1 == storage && $3 == "active" { found = 1 }
    END { exit !found }
' || die "storage is not active or does not exist: $STORAGE"

ip link show "$BRIDGE" >/dev/null 2>&1 \
    || die "bridge does not exist on this node: $BRIDGE"

if qm config "$VMID" >/dev/null 2>&1; then
    die "VMID $VMID is already occupied"
fi

[[ "$MACHINE" == q35 ]] || printf 'warning: MACHINE=%s is not q35\n' "$MACHINE" >&2
[[ "$BIOS" == ovmf ]] || printf 'warning: BIOS=%s is not ovmf\n' "$BIOS" >&2

if [[ -z ${SSH_PUBLIC_KEY_FILE:-} ]]; then
    printf '%s\n' 'warning: SSH_PUBLIC_KEY_FILE is not set; key validation deferred' >&2
elif [[ ! -r $SSH_PUBLIC_KEY_FILE ]]; then
    die "SSH_PUBLIC_KEY_FILE is not readable"
elif grep -q 'PRIVATE KEY' "$SSH_PUBLIC_KEY_FILE"; then
    die "SSH_PUBLIC_KEY_FILE appears to contain a private key"
else
    ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1 \
        || die "SSH_PUBLIC_KEY_FILE is not a valid public key"
fi

printf '%s\n' \
    "PVE validation passed; this script made no changes." \
    "VMID $VMID is available." \
    "Storage $STORAGE is active." \
    "Bridge $BRIDGE exists." \
    "Machine/firmware request: $MACHINE/$BIOS."
