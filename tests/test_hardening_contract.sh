#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
harden_script="$repo_root/scripts/harden-guest.sh"
validate_script="$repo_root/scripts/validate-hardening.sh"
example_env="$repo_root/config/hardening.example.env"

[[ -x "$harden_script" ]] || { printf '%s\n' 'hardening script is not executable' >&2; exit 1; }
[[ -x "$validate_script" ]] || { printf '%s\n' 'hardening validator is not executable' >&2; exit 1; }

grep -Fxq 'ENABLE_FIREWALL=false' "$example_env"
grep -Fxq 'ENABLE_LLMNR=false' "$example_env"
grep -Fq 'ADMIN_SSH_PUBLIC_KEY_FILE' "$harden_script"
grep -Fq 'sudo -n true' "$harden_script"
grep -Fq 'nft -c -f' "$harden_script"
grep -Fq 'systemd-run --unit="$rollback_unit"' "$harden_script"
grep -Fq 'LLMNR=no' "$harden_script"
grep -Fq 'permitrootlogin no' "$validate_script"
grep -Fq 'hermes-gateway.service' "$validate_script"
! grep -Fq 'RUN_RUNTIME_SMOKE' "$validate_script"

printf '%s\n' 'hardening contract passed.'
