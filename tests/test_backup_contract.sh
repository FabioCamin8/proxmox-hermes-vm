#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

scripts=(
    "$repo_root/scripts/lib/hermes-backup.sh"
    "$repo_root/scripts/backup-hermes-state.sh"
    "$repo_root/scripts/restore-hermes-state.sh"
    "$repo_root/scripts/validate-backup.sh"
)
for script in "${scripts[@]}"; do
    [[ -f "$script" ]] || { printf 'missing script: %s\n' "$script" >&2; exit 1; }
    grep -Fq 'set -Eeuo pipefail' "$script"
done

grep -Fq 'BACKUP_DESTINATION_KIND=off-host' "$repo_root/config/backup.example.env"
grep -Fq 'BACKUP_PASSWORD_FILE=/etc/hermes-backup/restic-password' \
    "$repo_root/config/backup.example.env"
grep -Fq 'BACKUP_DESTINATION_KIND must be explicitly set to off-host' \
    "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'off-host backups must use a remote restic repository form' \
    "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'hermes-state-metadata' "$repo_root/scripts/backup-hermes-state.sh"
grep -Fq 'hermes-state-data' "$repo_root/scripts/restore-hermes-state.sh"
grep -Fq 'restic metadata snapshot is missing' "$repo_root/scripts/validate-backup.sh"
grep -Fq -- '--json' "$repo_root/scripts/backup-hermes-state.sh"
grep -Fq 'source_bytes_processed=' "$repo_root/scripts/backup-hermes-state.sh"
grep -Fq 'stored_bytes_added=' "$repo_root/scripts/backup-hermes-state.sh"
grep -Fq 'backup password file must be root-owned with mode 0600' \
    "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'backup password file must not be under HERMES_HOME' \
    "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'PRAGMA quick_check' "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'database-wal' "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'Chromium did not exit cleanly' "$repo_root/scripts/backup-hermes-state.sh"
! grep -R --line-number --fixed-strings 'kill -9' "$repo_root/scripts" "$repo_root/systemd"
grep -Fq 'refusing to restore over or below HERMES_HOME' \
    "$repo_root/scripts/lib/hermes-backup.sh"
grep -Fq 'plaintext restore tree was removed' \
    "$repo_root/scripts/restore-hermes-state.sh"
grep -Fq 'ProtectHome=read-only' "$repo_root/systemd/hermes-state-backup.service"

guard_env=$(mktemp)
guard_output=$(mktemp)
existing_target=/var/tmp/hermes-restore-test-existing-contract
empty_env=$(mktemp)
empty_restic=$(mktemp)
empty_output=$(mktemp)
empty_password=$(mktemp)
cleanup() {
    rm -f -- "$guard_env" "$guard_output" "$empty_env" "$empty_restic" \
        "$empty_output" "$empty_password"
    rm -rf -- "$existing_target"
}
trap cleanup EXIT

if bash -c 'source "$1"; HERMES_HOME=/home/hermes; backup_validate_restore_target /var/tmp/hermes-restore-test-contract/nested' _ \
    "$repo_root/scripts/lib/hermes-backup.sh" >"$guard_output" 2>&1; then
    printf '%s\n' 'nested restore-target guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'restore target must be a direct /var/tmp child' "$guard_output"

printf '%s\n' \
    'BACKUP_DESTINATION_KIND=off-host' \
    'BACKUP_REPOSITORY=sftp:backup:/repo' \
    'BACKUP_PASSWORD_FILE='"$empty_password" \
    'RESTIC_BIN='"$empty_restic" >"$empty_env"
chmod 600 "$empty_password"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case ${1:-} in' \
    '  check) exit 0 ;;' \
    '  snapshots) printf "%s\\n" "[]"; exit 0 ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$empty_restic"
chmod 700 "$empty_restic"
if bash "$repo_root/scripts/validate-backup.sh" --env "$empty_env" \
    >"$empty_output" 2>&1; then
    printf '%s\n' 'empty snapshot guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'restic data snapshot is missing' "$empty_output"

printf 'HERMES_HOME=/var/tmp/hermes-restore-test-live\n' >"$guard_env"
if bash "$repo_root/scripts/restore-hermes-state.sh" \
    --env "$guard_env" --target /var/tmp/hermes-restore-test-live \
    >"$guard_output" 2>&1; then
    printf '%s\n' 'restore live-home guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'refusing to restore over or below HERMES_HOME' "$guard_output"

if bash -c 'source "$1"; BACKUP_DESTINATION_KIND=off-host; BACKUP_REPOSITORY=/var/tmp/plaintext; backup_require_off_host_destination' _ \
    "$repo_root/scripts/lib/hermes-backup.sh" >"$guard_output" 2>&1; then
    printf '%s\n' 'local destination guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'off-host backups must use a remote restic repository form' "$guard_output"

if bash -c 'source "$1"; BACKUP_DESTINATION_KIND=off-host; BACKUP_REPOSITORY=sftp:backup:/repo; BACKUP_PASSWORD_FILE=/var/tmp/missing-hermes-password; HERMES_HOME=/home/hermes; backup_require_secure_password_file' _ \
    "$repo_root/scripts/lib/hermes-backup.sh" >"$guard_output" 2>&1; then
    printf '%s\n' 'missing password-file guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'backup password file must be a regular non-symlink file' "$guard_output"

mkdir -- "$existing_target"
if bash "$repo_root/scripts/restore-hermes-state.sh" \
    --env "$guard_env" --target "$existing_target" \
    >"$guard_output" 2>&1; then
    printf '%s\n' 'existing restore-target guard unexpectedly passed' >&2
    exit 1
fi
grep -Fq 'restore target already exists' "$guard_output"

printf '%s\n' 'backup contract tests passed.'
