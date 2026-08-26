#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hermes-backup.sh
source "$script_dir/lib/hermes-backup.sh"

usage() {
    cat <<'EOF'
Usage: backup-hermes-state.sh --env FILE [--dry-run]

The configured destination must be explicitly declared off-host. The backup
password file is root-controlled and must live outside HERMES_HOME.
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
backup_validate_configuration

if [[ "$dry_run" == true ]]; then
    printf '%s\n' 'dry-run: configuration and state manifest inputs are valid.'
    exit 0
fi

backup_require_off_host_destination
backup_require_secure_password_file
command -v "$RESTIC_BIN" >/dev/null 2>&1 || backup_die "restic command is unavailable: $RESTIC_BIN"
command -v fuser >/dev/null 2>&1 || backup_die 'fuser is required to prove database quiescence'
[[ -x /usr/bin/python3 ]] || backup_die '/usr/bin/python3 is required for SQLite checks'

uid=$(id -u "$HERMES_USER")
runtime_dir=/run/user/$uid
systemd_bus_address="unix:path=$runtime_dir/bus"
hermes_systemctl() {
    runuser -u "$HERMES_USER" -- env \
        HOME="$HERMES_HOME" \
        XDG_RUNTIME_DIR="$runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="$systemd_bus_address" \
        PATH="$HERMES_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        systemctl --user "$@"
}

hermes_systemctl is-active --quiet hermes-gateway.service \
    || backup_die 'Hermes gateway must be active before backup'

temp_dir=$(mktemp -d /var/tmp/hermes-state-backup.XXXXXX)
chmod 700 "$temp_dir"
[[ "$temp_dir" == /var/tmp/hermes-state-backup.* ]] || backup_die 'unexpected backup temp path'
manifest_file="$temp_dir/files-from"
metadata_file="$temp_dir/metadata"
cleanup_temp_dir() {
    local saved_status=$?
    set +e
    rm -rf -- "$temp_dir"
    exit "$saved_status"
}
trap cleanup_temp_dir EXIT
backup_build_manifest "$manifest_file"
backup_write_metadata "$metadata_file" "$manifest_file"
trap - EXIT

gateway_was_active=true
browser_was_running=false
browser_pids=()
cleanup() {
    local saved_status=$?
    local cleanup_status=0
    set +e

    if [[ "$browser_was_running" == true ]]; then
        runuser -u "$HERMES_USER" -- env \
            HOME="$HERMES_HOME" \
            PATH="$HERMES_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
            "$HERMES_HOME/.local/bin/hermes-graphical" \
            "$HERMES_HOME/.local/bin/hermes-session-start" \
            >/dev/null 2>&1 &
        sleep 2
        pgrep -u "$uid" -x chromium >/dev/null 2>&1 || cleanup_status=1
    fi
    if [[ "$gateway_was_active" == true ]]; then
        hermes_systemctl start hermes-gateway.service || cleanup_status=1
        hermes_systemctl is-active --quiet hermes-gateway.service || cleanup_status=1
    fi

    rm -rf -- "$temp_dir"
    if (( saved_status == 0 && cleanup_status != 0 )); then
        saved_status=1
        printf '%s\n' 'error: live Hermes components did not fully restart after backup' >&2
    fi
    exit "$saved_status"
}
trap cleanup EXIT

if [[ "$INCLUDE_CHROMIUM_PROFILE" == true ]]; then
    mapfile -t browser_pids < <(pgrep -u "$uid" -x chromium || true)
    if ((${#browser_pids[@]} > 0)); then
        browser_was_running=true
        for pid in "${browser_pids[@]}"; do
            kill -TERM "$pid" 2>/dev/null || true
        done
        remaining=1
        for attempt in {1..60}; do
            remaining=0
            for pid in "${browser_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    remaining=1
                fi
            done
            if (( remaining == 0 )); then
                break
            fi
            sleep 1
        done
        (( remaining == 0 )) || backup_die 'Chromium did not exit cleanly'
    fi
fi

hermes_systemctl stop hermes-gateway.service
if hermes_systemctl is-active --quiet hermes-gateway.service; then
    backup_die 'Hermes gateway remained active after stop'
fi

for database in \
    "$HERMES_HOME/.hermes/state.db" \
    "$HERMES_HOME/.hermes/kanban.db" \
    "$HERMES_HOME/.hermes/cron/executions.db"; do
    for database_file in "$database" "$database-wal" "$database-shm"; do
        if [[ -e "$database_file" ]] && fuser -s "$database_file"; then
            backup_die "database remains open after quiesce: $database_file"
        fi
    done
    backup_sqlite_quick_check "$database" \
        || backup_die "live SQLite quick_check failed before backup: $database"
done

if ! backup_restic backup \
    --files-from "$manifest_file" \
    --tag hermes-state \
    --tag hermes-state-data \
    --tag hermes-format-v1 \
    --exclude='*/Cache/*' \
    --exclude='*/Code Cache/*' \
    --exclude='*/GPUCache/*' \
    --exclude='*/DawnCache/*' \
    --exclude='*/ShaderCache/*' \
    --exclude='*/GrShaderCache/*' \
    --exclude='*/Service Worker/CacheStorage/*' \
    --exclude='*/cron/output/*' \
    --exclude='*/.jobs.lock' \
    --exclude='*/.tick.lock' \
    --exclude='*/gateway.lock' \
    --exclude='*/gateway.pid' \
    --exclude='*/ticker_*' \
    >"$temp_dir/restic-backup.log" 2>&1; then
    backup_die 'encrypted restic backup failed; no sensitive command output is displayed'
fi

if ! backup_restic backup \
    --stdin \
    --stdin-filename hermes-state-manifest.txt \
    --tag hermes-state \
    --tag hermes-state-metadata \
    <"$metadata_file" >"$temp_dir/restic-metadata.log" 2>&1; then
    backup_die 'encrypted metadata backup failed; no sensitive command output is displayed'
fi

if ! backup_restic check >"$temp_dir/restic-check.log" 2>&1; then
    backup_die 'restic integrity check failed; no sensitive command output is displayed'
fi

if [[ "$APPLY_RETENTION" == true ]]; then
    if ! backup_restic forget \
        --tag hermes-state \
        --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" \
        --keep-monthly "$KEEP_MONTHLY" \
        --prune >"$temp_dir/restic-retention.log" 2>&1; then
        backup_die 'restic retention operation failed; no sensitive command output is displayed'
    fi
fi

snapshot_id=
if backup_restic snapshots --tag hermes-state-data --latest 1 --json >"$temp_dir/snapshots.json" 2>/dev/null; then
    snapshot_id=$(awk -F'"' '/"id"[[:space:]]*:/ { print $4; exit }' "$temp_dir/snapshots.json")
fi
[[ -n "$snapshot_id" ]] || backup_die 'could not determine encrypted backup snapshot ID'

metadata_snapshot_id=
if backup_restic snapshots --tag hermes-state-metadata --latest 1 --json >"$temp_dir/metadata-snapshots.json" 2>/dev/null; then
    metadata_snapshot_id=$(awk -F'"' '/"id"[[:space:]]*:/ { print $4; exit }' "$temp_dir/metadata-snapshots.json")
fi
[[ -n "$metadata_snapshot_id" ]] || backup_die 'could not determine encrypted metadata snapshot ID'

printf 'backup_snapshot=%s\n' "$snapshot_id"
printf 'metadata_snapshot=%s\n' "$metadata_snapshot_id"
printf 'manifest_sha256=%s\n' "$(sha256sum "$manifest_file" | awk '{print $1}')"
printf 'metadata_sha256=%s\n' "$(sha256sum "$metadata_file" | awk '{print $1}')"
printf '%s\n' 'encrypted backup and repository integrity check passed.'
