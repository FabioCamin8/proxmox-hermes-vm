#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/hermes-backup.sh
source "$script_dir/lib/hermes-backup.sh"

usage() {
    cat <<'EOF'
Usage: restore-hermes-state.sh --env FILE --target DIRECTORY [--snapshot ID]

The target must not exist, must be under /var/tmp/hermes-restore-test-, and is
always removed after validation. This command never restores over HERMES_HOME.
EOF
}

env_file=
target=
snapshot_request=latest
while (($# > 0)); do
    case $1 in
        --env)
            (($# >= 2)) || backup_die '--env requires a file'
            env_file=$2
            shift 2
            ;;
        --target)
            (($# >= 2)) || backup_die '--target requires a directory'
            target=$2
            shift 2
            ;;
        --snapshot)
            (($# >= 2)) || backup_die '--snapshot requires an ID'
            snapshot_request=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *) backup_die "unknown argument: $1" ;;
    esac
done

[[ -n "$env_file" ]] || backup_die '--env is required'
[[ -n "$target" ]] || backup_die '--target is required'
backup_load_env "$env_file"
backup_set_defaults

[[ "$target" == /* ]] || backup_die '--target must be absolute'
[[ "$target" == /var/tmp/hermes-restore-test-* ]] \
    || backup_die '--target must match /var/tmp/hermes-restore-test-*'
[[ "$target" != "$HERMES_HOME" && "$target" != "$HERMES_HOME"/* ]] \
    || backup_die 'refusing to restore over or below HERMES_HOME'
[[ ! -e "$target" ]] || backup_die 'restore target already exists'

backup_validate_runtime_options
backup_require_root
backup_require_runtime_identity
backup_require_off_host_destination
backup_require_secure_password_file
command -v "$RESTIC_BIN" >/dev/null 2>&1 || backup_die "restic command is unavailable: $RESTIC_BIN"
[[ -x /usr/bin/python3 ]] || backup_die '/usr/bin/python3 is required for SQLite checks'

target_parent=$(dirname -- "$target")
[[ -d "$target_parent" ]] || backup_die 'restore target parent does not exist'
[[ "$(stat -c '%u' "$target_parent")" == 0 ]] || backup_die 'restore target parent must be root-owned'

mkdir -- "$target"
chmod 700 "$target"
created_target=true
temp_json=
cleanup() {
    local saved_status=$?
    set +e
    [[ -z "$temp_json" ]] || rm -f -- "$temp_json"
    if [[ "$created_target" == true && "$target" == /var/tmp/hermes-restore-test-* ]]; then
        rm -rf -- "$target"
    fi
    if (( saved_status == 0 )); then
        [[ ! -e "$target" ]] || saved_status=1
    fi
    exit "$saved_status"
}
trap cleanup EXIT

temp_json=$(mktemp /var/tmp/hermes-restore-snapshots.XXXXXX)
chmod 600 "$temp_json"
snapshot_args=(snapshots --tag hermes-state-data --json)
if [[ "$snapshot_request" == latest ]]; then
    snapshot_args+=(--latest 1)
fi
backup_restic "${snapshot_args[@]}" >"$temp_json" 2>/dev/null \
    || backup_die 'could not list encrypted Hermes snapshots'

snapshot_id=
if [[ "$snapshot_request" == latest ]]; then
    snapshot_id=$(awk -F'"' '/"id"[[:space:]]*:/ { print $4; exit }' "$temp_json")
else
    snapshot_id=$(awk -F'"' -v wanted="$snapshot_request" \
        '/"id"[[:space:]]*:/ && $4 == wanted { print $4; exit }' "$temp_json")
fi
[[ -n "$snapshot_id" ]] || backup_die 'requested snapshot is not a hermes-state data snapshot'

backup_restic restore "$snapshot_id" --target "$target" --verify \
    >"$target/.restic-restore.log" 2>&1 \
    || backup_die 'encrypted restore failed; no sensitive command output is displayed'
rm -f -- "$target/.restic-restore.log"

backup_validate_restored_tree "$target"
printf 'restored_snapshot=%s\n' "$snapshot_id"
printf '%s\n' 'isolated restore completed; plaintext restore tree was removed.'
