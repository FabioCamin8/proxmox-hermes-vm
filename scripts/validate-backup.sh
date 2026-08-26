#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hermes-backup.sh
source "$script_dir/lib/hermes-backup.sh"

usage() {
    cat <<'EOF'
Usage: validate-backup.sh --env FILE [--dry-run]

Runs restic's repository integrity check without restoring or changing live
Hermes state. Use restore-hermes-state.sh for an isolated restore validation.
EOF
}

env_file=
dry_run=false
while (($# > 0)); do
    case $1 in
        --env)
            (($# >= 2)) || backup_die '--env requires a file'
            env_file=$2
            shift 2
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) backup_die "unknown argument: $1" ;;
    esac
done

[[ -n "$env_file" ]] || backup_die '--env is required'
backup_load_env "$env_file"
backup_set_defaults
backup_validate_runtime_options
backup_require_root
backup_require_off_host_destination
backup_require_secure_password_file

if [[ "$dry_run" == true ]]; then
    printf '%s\n' 'dry-run: backup repository configuration is valid.'
    exit 0
fi

command -v "$RESTIC_BIN" >/dev/null 2>&1 || backup_die "restic command is unavailable: $RESTIC_BIN"
if ! backup_restic check >/dev/null 2>&1; then
    backup_die 'restic repository integrity check failed; no sensitive command output is displayed'
fi
if ! backup_restic snapshots --tag hermes-state-data --latest 1 >/dev/null 2>&1; then
    backup_die 'restic data snapshot is missing; no sensitive command output is displayed'
fi
if ! backup_restic snapshots --tag hermes-state-metadata --latest 1 >/dev/null 2>&1; then
    backup_die 'restic metadata snapshot is missing; no sensitive command output is displayed'
fi
printf '%s\n' 'restic repository integrity check passed.'
