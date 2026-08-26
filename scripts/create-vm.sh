#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: create-vm.sh (--dry-run|--apply) ENV_FILE

--dry-run validates the local Proxmox, storage, network, image, and Cloud-Init
inputs and prints the plan without downloading or creating anything.
--apply performs the same preflight, verifies the image, creates the VM, and
prints the exact attached volume references and start state.
EOF
}

die_range() {
    local name=$1 value=$2 minimum=$3 maximum=$4
    [[ "$value" =~ ^[0-9]+$ ]] || die "$name must be an integer"
    ((10#$value >= minimum && 10#$value <= maximum)) \
        || die "$name must be between $minimum and $maximum"
}

require_identifier() {
    local name=$1 value=$2
    [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "$name contains unsupported characters"
}

require_account_name() {
    local name=$1 value=$2
    [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "$name is not a valid Unix account name"
    [[ "$value" != root ]] || die "$name must not be root"
}

require_https_debian_image() {
    local value=$1
    [[ "$value" =~ ^https://cloud\.debian\.org/images/cloud/[^/]+/debian-[0-9]+-genericcloud-amd64\.qcow2$ ]] \
        || die 'IMAGE_URL must be an official Debian cloud.debian.org genericcloud amd64 qcow2 URL'
}

require_https_debian_checksum() {
    local value=$1
    [[ "$value" =~ ^https://cloud\.debian\.org/images/cloud/[^/]+/SHA512SUMS$ ]] \
        || die 'IMAGE_CHECKSUM_URL must be the matching official Debian SHA512SUMS URL'
}

verify_checksum_manifest() {
    local manifest=$1 image_name=$2
    local matches=()
    mapfile -t matches < <(awk -v image="$image_name" \
        '$NF == image || $NF == "./" image { print $1 }' "$manifest")
    ((${#matches[@]} == 1)) \
        || die "checksum manifest does not contain exactly one entry for $image_name"
    [[ "${matches[0]}" =~ ^[[:xdigit:]]{128}$ ]] \
        || die "checksum manifest entry for $image_name is not SHA512"
    printf '%s\n' "${matches[0]}"
}

verify_sha512() {
    local expected=$1 file=$2
    printf '%s  %s\n' "$expected" "$file" | sha512sum --check --status - \
        || die "SHA512 verification failed: $file"
}

download_verified_image() {
    local image_file=$1 image_name=$2 expected=$3
    download_file=

    if [[ -f "$image_file" && ! -L "$image_file" ]]; then
        if printf '%s  %s\n' "$expected" "$image_file" | sha512sum --check --status -; then
            printf '%s\n' "Using verified cached image: $image_file"
            return 0
        fi
        printf '%s\n' "Cached image checksum differs; replacing it atomically: $image_file" >&2
    fi

    download_file=$(mktemp "$IMAGE_CACHE_DIR/.${image_name}.download.XXXXXX")
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        "$IMAGE_URL" --output "$download_file" \
        || die "unable to download Debian image: $IMAGE_URL"
    verify_sha512 "$expected" "$download_file"
    mv -f -- "$download_file" "$image_file"
    download_file=
    printf '%s\n' "Downloaded and verified image: $image_file"
}

[[ ${1:-} == --dry-run || ${1:-} == --apply ]] || {
    usage >&2
    exit 2
}
[[ $# -eq 2 ]] || {
    usage >&2
    exit 2
}

mode=$1
env_file=$2
load_env "$env_file"

for name in VMID VM_NAME STORAGE BRIDGE CPU_TYPE CORES MEMORY_MB DISK_SIZE_GB \
    MACHINE BIOS CI_USER SSH_PUBLIC_KEY_FILE IPCONFIG0 CIUPGRADE IMAGE_URL \
    IMAGE_CHECKSUM_URL; do
    require_var "$name"
done

MTU=${MTU:-1500}
VLAN_ID=${VLAN_ID:-}
START_VM=${START_VM:-0}
IMAGE_CACHE_DIR=${IMAGE_CACHE_DIR:-/var/lib/vz/template/cache}

die_range VMID "$VMID" 100 999999999
die_range CORES "$CORES" 1 128
die_range MEMORY_MB "$MEMORY_MB" 512 1048576
die_range DISK_SIZE_GB "$DISK_SIZE_GB" 1 65536
die_range MTU "$MTU" 576 65535
[[ "$START_VM" == 0 || "$START_VM" == 1 ]] || die 'START_VM must be 0 or 1'
[[ -z "$VLAN_ID" ]] || die_range VLAN_ID "$VLAN_ID" 1 4094

require_identifier STORAGE "$STORAGE"
require_identifier BRIDGE "$BRIDGE"
[[ "$VM_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] \
    || die 'VM_NAME must be a 1-63 character hostname-safe name'
[[ "$CPU_TYPE" =~ ^[A-Za-z0-9_.+-]+$ ]] \
    || die 'CPU_TYPE contains unsupported characters'
[[ "$MACHINE" == q35 ]] || die 'MACHINE must be q35'
[[ "$BIOS" == ovmf ]] || die 'BIOS must be ovmf'
require_account_name CI_USER "$CI_USER"
[[ "$IPCONFIG0" == ip=dhcp ]] || die 'IPCONFIG0 must be exactly ip=dhcp'
[[ "$CIUPGRADE" == 0 || "$CIUPGRADE" == 1 ]] || die 'CIUPGRADE must be 0 or 1'
[[ "$IMAGE_CACHE_DIR" == /* ]] || die 'IMAGE_CACHE_DIR must be an absolute path'
require_https_debian_image "$IMAGE_URL"
require_https_debian_checksum "$IMAGE_CHECKSUM_URL"
[[ "${IMAGE_URL%/*}" == "${IMAGE_CHECKSUM_URL%/*}" ]] \
    || die 'IMAGE_URL and IMAGE_CHECKSUM_URL must use the same Debian release directory'

[[ -f "$SSH_PUBLIC_KEY_FILE" && -r "$SSH_PUBLIC_KEY_FILE" ]] \
    || die 'SSH_PUBLIC_KEY_FILE must be a readable public-key file'
if grep -q 'PRIVATE KEY' "$SSH_PUBLIC_KEY_FILE"; then
    die 'SSH_PUBLIC_KEY_FILE appears to contain a private key'
fi
ssh-keygen -lf "$SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1 \
    || die 'SSH_PUBLIC_KEY_FILE is not a valid public key'

for command_name in awk curl ip install mktemp mv pveversion pvesm qm sha512sum ssh-keygen; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command is unavailable: $command_name"
done

pveversion -v >/dev/null || die 'unable to query the Proxmox version'
qm help create >/dev/null 2>&1 || die 'qm create is unavailable'
qm help importdisk >/dev/null 2>&1 || die 'qm importdisk is unavailable'
qm help set >/dev/null 2>&1 || die 'qm set is unavailable'
qm help cloudinit >/dev/null 2>&1 || die 'qm cloudinit is unavailable'

if qm config "$VMID" >/dev/null 2>&1; then
    die "VMID $VMID already exists; refusing to overwrite it"
fi

pvesm status --storage "$STORAGE" --content images | awk -v storage="$STORAGE" '
    $1 == storage && $3 == "active" { found = 1 }
    END { exit !found }
' || die "storage is not active or does not support VM images: $STORAGE"

ip link show dev "$BRIDGE" >/dev/null 2>&1 \
    || die "bridge does not exist on this node: $BRIDGE"
[[ -d "/sys/class/net/$BRIDGE/bridge" ]] \
    || die "network interface is not a Linux bridge: $BRIDGE"

image_name=${IMAGE_URL##*/}
image_file="$IMAGE_CACHE_DIR/$image_name"

printf '%s\n' \
    'Preflight passed.' \
    "VMID=$VMID" \
    "VM_NAME=$VM_NAME" \
    "STORAGE=$STORAGE" \
    "BRIDGE=$BRIDGE" \
    "MTU=$MTU" \
    "CPU_TYPE=$CPU_TYPE" \
    "CORES=$CORES" \
    "MEMORY_MB=$MEMORY_MB" \
    "DISK_SIZE_GB=$DISK_SIZE_GB" \
    "MACHINE=$MACHINE" \
    "BIOS=$BIOS" \
    "CI_USER=$CI_USER" \
    "IMAGE_URL=$IMAGE_URL" \
    "IMAGE_CHECKSUM_URL=$IMAGE_CHECKSUM_URL" \
    "IMAGE_CACHE=$image_file" \
    "START_VM=$START_VM"

if [[ "$mode" == --dry-run ]]; then
    printf '%s\n' 'Dry run complete; no image download or Proxmox changes were made.'
    exit 0
fi

install -d -m 0755 "$IMAGE_CACHE_DIR"
manifest_file=$(mktemp "$IMAGE_CACHE_DIR/.SHA512SUMS.XXXXXX")
trap 'rm -f -- "${manifest_file:-}" "${download_file:-}"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    "$IMAGE_CHECKSUM_URL" --output "$manifest_file" \
    || die "unable to download Debian checksum manifest: $IMAGE_CHECKSUM_URL"
expected_sha512=$(verify_checksum_manifest "$manifest_file" "$image_name")
download_verified_image "$image_file" "$image_name" "$expected_sha512"

net_config="virtio,bridge=$BRIDGE,mtu=$MTU"
[[ -z "$VLAN_ID" ]] || net_config+=",tag=$VLAN_ID"

qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype l26 \
    --machine "$MACHINE" \
    --bios "$BIOS" \
    --cpu "$CPU_TYPE" \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --scsihw virtio-scsi-single \
    --net0 "$net_config" \
    --agent 1 \
    --serial0 socket \
    --vga std \
    --efidisk0 "$STORAGE:0,efitype=4m,pre-enrolled-keys=0" \
    --onboot 0

import_output=$(qm importdisk "$VMID" "$image_file" "$STORAGE" --format qcow2 2>&1) \
    || die 'qm importdisk failed for the verified Debian image'
imported_volume=$(awk -F': ' '$1 ~ /^unused[0-9]+$/ { print $2; exit }' <<<"$import_output")
if [[ -z "$imported_volume" ]]; then
    imported_volume=$(qm config "$VMID" | awk '$1 ~ /^unused[0-9]+:/ { print $2; exit }')
fi
[[ -n "$imported_volume" ]] \
    || die 'qm importdisk did not expose an imported unused volume reference'

post_import_config=$(qm config "$VMID")
grep -Fq " $imported_volume" <<<"$post_import_config" \
    || die 'the imported volume reference was not present in qm config'

qm set "$VMID" --scsi0 "$imported_volume,discard=on,ssd=1,iothread=1"
attached_volume=$(qm config "$VMID" | awk '$1 == "scsi0:" { sub(/,.*/, "", $2); print $2; exit }')
[[ "$attached_volume" == "$imported_volume" ]] \
    || die 'the attached scsi0 volume does not match the imported Debian volume'

qm resize "$VMID" scsi0 "${DISK_SIZE_GB}G"
qm set "$VMID" --scsi1 "$STORAGE:cloudinit,media=cdrom"
qm set "$VMID" \
    --ciuser "$CI_USER" \
    --sshkeys "$SSH_PUBLIC_KEY_FILE" \
    --ipconfig0 "$IPCONFIG0" \
    --ciupgrade "$CIUPGRADE" \
    --boot order=scsi0
qm cloudinit update "$VMID"

final_config=$(qm config "$VMID")
final_attached_volume=$(awk '$1 == "scsi0:" { sub(/,.*/, "", $2); print $2; exit }' <<<"$final_config")
cloudinit_drive=$(awk '$1 == "scsi1:" { print $2; exit }' <<<"$final_config")
[[ "$final_attached_volume" == "$imported_volume" ]] \
    || die 'final qm config no longer points scsi0 at the imported Debian volume'
[[ -n "$cloudinit_drive" ]] || die 'final qm config has no Cloud-Init drive on scsi1'
grep -Eq '^boot: order=scsi0([;[:space:]]|$)' <<<"$final_config" \
    || die 'final qm config does not boot from scsi0'
grep -Eq '^agent: 1$' <<<"$final_config" \
    || die 'final qm config does not enable the QEMU Guest Agent option'
grep -Eq '^serial0: socket$' <<<"$final_config" \
    || die 'final qm config does not expose a serial console'
grep -Eq '^vga: std$' <<<"$final_config" \
    || die 'final qm config does not expose a graphical display'

start_state=stopped
if [[ "$START_VM" == 1 ]]; then
    qm start "$VMID"
    start_state=started
fi

printf '%s\n' \
    'VM creation completed.' \
    "VMID=$VMID" \
    "VM_NAME=$VM_NAME" \
    "BOOT_VOLUME=$final_attached_volume" \
    "CLOUD_INIT_DRIVE=$cloudinit_drive" \
    "START_STATE=$start_state" \
    "IMAGE_SHA512=$expected_sha512" \
    'Next action: wait for Cloud-Init and DHCP, then connect with the supplied public-key identity and run the guest validator.'
