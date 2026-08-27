#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

usage() {
    printf '%s\n' 'Usage: validate-pve.sh [--existing] ENV_FILE'
}

existing_vm=false
if [[ $# -eq 1 ]]; then
    env_file=$1
elif [[ $# -eq 2 && $1 == --existing ]]; then
    existing_vm=true
    env_file=$2
else
    usage >&2
    exit 2
fi
load_env "$env_file"

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

pvesm status --storage "$STORAGE" --content images | awk -v storage="$STORAGE" '
    $1 == storage && $3 == "active" { found = 1 }
    END { exit !found }
' || die "storage is not active or does not exist: $STORAGE"

ip link show "$BRIDGE" >/dev/null 2>&1 \
    || die "bridge does not exist on this node: $BRIDGE"

vm_config=
if qm config "$VMID" >/dev/null 2>&1; then
    if [[ "$existing_vm" == true ]]; then
        vm_config=$(qm config "$VMID")
    else
        die "VMID $VMID is already occupied"
    fi
elif [[ "$existing_vm" == true ]]; then
    die "VMID $VMID does not exist"
fi

[[ "$MACHINE" == q35 ]] || die 'MACHINE must be q35 for the graphical VM'
[[ "$BIOS" == ovmf ]] || die 'BIOS must be ovmf for the graphical VM'

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

if [[ "$existing_vm" == true ]]; then
    for required_setting in \
        'machine: q35' \
        'bios: ovmf' \
        'vga: virtio' \
        'tablet: 1'; do
        grep -Fxq -- "$required_setting" <<<"$vm_config" \
            || die "existing VM config is missing required setting: $required_setting"
    done
    printf '%s\n' \
        'PVE configuration validation passed; this script made no changes.' \
        "VMID $VMID config has machine=q35 bios=ovmf vga=virtio tablet=1."
    exit 0
fi

printf '%s\n' \
    "PVE validation passed; this script made no changes." \
    "VMID $VMID is available." \
    "Storage $STORAGE is active." \
    "Bridge $BRIDGE exists." \
    "Machine/firmware request: $MACHINE/$BIOS." \
    'Graphical device request: vga=virtio tablet=1.'
