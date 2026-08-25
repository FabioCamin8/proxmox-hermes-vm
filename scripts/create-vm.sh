#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: create-vm.sh --dry-run ENV_FILE

The initial repository intentionally exposes only a validated preflight and
plan. An apply path must be implemented and tested on a disposable VM before
it is enabled.
EOF
}

[[ ${1:-} == --dry-run ]] || {
    usage >&2
    exit 2
}
[[ $# -eq 2 ]] || {
    usage >&2
    exit 2
}

load_env "$2"

for name in VMID VM_NAME STORAGE BRIDGE CPU_TYPE CORES MEMORY_MB DISK_SIZE_GB \
    MACHINE BIOS CI_USER SSH_PUBLIC_KEY_FILE IPCONFIG0 CIUPGRADE IMAGE_URL; do
    require_var "$name"
done
require_integer VMID
require_integer CORES
require_integer MEMORY_MB
require_integer DISK_SIZE_GB

[[ -r "$SSH_PUBLIC_KEY_FILE" ]] || die "SSH public key file is not readable"
if grep -q 'PRIVATE KEY' "$SSH_PUBLIC_KEY_FILE"; then
    die "SSH_PUBLIC_KEY_FILE appears to contain a private key"
fi
ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1 \
    || die "SSH_PUBLIC_KEY_FILE is not a valid public key"

for command_name in qm pvesm ip curl; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command is unavailable: $command_name"
done

if qm config "$VMID" >/dev/null 2>&1; then
    die "VMID $VMID already exists; refusing to overwrite it"
fi

pvesm status | awk -v storage="$STORAGE" '
    $1 == storage && $3 == "active" { found = 1 }
    END { exit !found }
' || die "storage is not active or does not exist: $STORAGE"

ip link show "$BRIDGE" >/dev/null 2>&1 \
    || die "bridge does not exist on this node: $BRIDGE"

image_cache_dir=${IMAGE_CACHE_DIR:-cache/images}
image_file="$image_cache_dir/$(basename -- "$IMAGE_URL")"

printf '%s\n' \
    "Preflight passed; no changes were made." \
    "VMID=$VMID" \
    "VM_NAME=$VM_NAME" \
    "STORAGE=$STORAGE" \
    "BRIDGE=$BRIDGE" \
    "MTU=${MTU:-1500}" \
    "CPU_TYPE=$CPU_TYPE" \
    "CORES=$CORES" \
    "MEMORY_MB=$MEMORY_MB" \
    "DISK_SIZE_GB=$DISK_SIZE_GB" \
    "MACHINE=$MACHINE" \
    "BIOS=$BIOS" \
    "CI_USER=$CI_USER" \
    "IMAGE_URL=$IMAGE_URL" \
    "IMAGE_CACHE=$image_file" \
    "Planned next actions:" \
    "  1. Download the selected image and verify its checksum." \
    "  2. Create a new VM only after a final VMID/storage review." \
    "  3. Import the image without guessing the resulting volume ID." \
    "  4. Attach SCSI and Cloud-Init drives, then validate the result." \
    "  5. Start only when the generated Cloud-Init payload is reviewed." \
    "Apply mode is intentionally not implemented in this initial release."
