#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
create_script="$repo_root/scripts/create-vm.sh"
runtime_script="$repo_root/scripts/validate-runtime.sh"
hermes_script="$repo_root/scripts/validate-hermes.sh"
config="$repo_root/config/example.env"
pve_script="$repo_root/scripts/validate-pve.sh"
proxmox_doc="$repo_root/docs/proxmox.md"

[[ -x "$create_script" ]] || { printf '%s\n' 'create-vm.sh is not executable' >&2; exit 1; }
[[ -x "$runtime_script" ]] || { printf '%s\n' 'validate-runtime.sh is not executable' >&2; exit 1; }
[[ -x "$hermes_script" ]] || { printf '%s\n' 'validate-hermes.sh is not executable' >&2; exit 1; }
[[ -x "$pve_script" ]] || { printf '%s\n' 'validate-pve.sh is not executable' >&2; exit 1; }

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
    '--vga virtio' \
    '--tablet 1' \
    "grep -Eq '^vga: virtio$'" \
    "grep -Eq '^tablet: 1$'" \
    '--scsi1 "$STORAGE:cloudinit,media=cdrom"' \
    'Next action: wait for Cloud-Init and DHCP'; do
    grep -Fq -- "$required_text" "$create_script"
done

! grep -Fq -- '--vga std' "$create_script"

for required_text in \
    'Usage: validate-pve.sh [--existing] ENV_FILE' \
    'existing VM config is missing required setting' \
    'qm config "$VMID"' \
    "MACHINE must be q35 for the graphical VM" \
    "BIOS must be ovmf for the graphical VM" \
    'Graphical device request: vga=virtio tablet=1'; do
    grep -Fq -- "$required_text" "$pve_script"
done

for required_text in \
    'scripts/validate-pve.sh --existing' \
    'reads the live `qm config` and makes no changes' \
    'vga: virtio' \
    'tablet: 1'; do
    grep -Fq -- "$required_text" "$proxmox_doc"
done

grep -Fq 'if ((doctor_status != 0)); then' "$hermes_script"
grep -Fq 'exit "$doctor_status"' "$hermes_script"
! grep -Fq 'provider-not-configured' "$hermes_script"

! grep -Fq 'IMAGE_SHA256_URL' "$config"
! grep -Fq -- '--format qcow2' "$create_script"
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
