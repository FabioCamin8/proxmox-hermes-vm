#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
create_script="$repo_root/scripts/create-vm.sh"
runtime_script="$repo_root/scripts/validate-runtime.sh"
config="$repo_root/config/example.env"

[[ -x "$create_script" ]] || { printf '%s\n' 'create-vm.sh is not executable' >&2; exit 1; }
[[ -x "$runtime_script" ]] || { printf '%s\n' 'validate-runtime.sh is not executable' >&2; exit 1; }

for required_text in \
    'Usage: create-vm.sh (--dry-run|--apply) ENV_FILE' \
    'IMAGE_CHECKSUM_URL' \
    'cloud.debian.org genericcloud amd64 qcow2 URL' \
    'sha512sum --check' \
    'qm importdisk' \
    'qm config' \
    '--scsihw virtio-scsi-single' \
    '--efidisk0' \
    '--serial0 socket' \
    '--vga std' \
    '--scsi1 "$STORAGE:cloudinit,media=cdrom"' \
    'Next action: wait for Cloud-Init and DHCP'; do
    grep -Fq -- "$required_text" "$create_script"
done

! grep -Fq 'IMAGE_SHA256_URL' "$config"
! grep -Fq 'qm destroy' "$create_script"
! grep -Fq 'qm stop' "$create_script"

for required_text in \
    'BASE        $(status_word' \
    'SECURITY    $(status_word' \
    'DESKTOP     $(status_word' \
    'BROWSER     $(status_word' \
    'CUA         $(status_word' \
    'PROVIDER    $provider_state' \
    'GATEWAY     $gateway_state' \
    'RUNTIME READY' \
    'computer_use_doctor=exit-0' \
    'sudo -n -u "$HERMES_USER"'; do
    grep -Fq -- "$required_text" "$runtime_script"
done

printf '%s\n' 'create/runtime contract tests passed.'
