#!/usr/bin/env bash

set -Eeuo pipefail

backup_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

backup_load_env() {
    local env_file=${1:?environment file is required}

    [[ -r "$env_file" ]] || backup_die "environment file is not readable: $env_file"
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
}

backup_set_defaults() {
    HERMES_USER=${HERMES_USER:-hermes}
    HERMES_HOME=${HERMES_HOME:-/home/hermes}
    BACKUP_REPOSITORY=${BACKUP_REPOSITORY:-}
    BACKUP_PASSWORD_FILE=${BACKUP_PASSWORD_FILE:-}
    BACKUP_DESTINATION_KIND=${BACKUP_DESTINATION_KIND:-unknown}
    RESTIC_BIN=${RESTIC_BIN:-restic}
    INCLUDE_CHROMIUM_PROFILE=${INCLUDE_CHROMIUM_PROFILE:-true}
    INCLUDE_SESSION_HISTORY=${INCLUDE_SESSION_HISTORY:-true}
    INCLUDE_USER_MEMORIES=${INCLUDE_USER_MEMORIES:-true}
    APPLY_RETENTION=${APPLY_RETENTION:-false}
    KEEP_DAILY=${KEEP_DAILY:-7}
    KEEP_WEEKLY=${KEEP_WEEKLY:-4}
    KEEP_MONTHLY=${KEEP_MONTHLY:-6}
}

backup_require_root() {
    [[ "$(id -u)" == 0 ]] || backup_die 'run this command as root through the ops administrative path'
}

backup_require_bool() {
    local name=$1
    local value=${!name:-}

    [[ "$value" == true || "$value" == false ]] || backup_die "$name must be true or false"
}

backup_require_integer() {
    local name=$1
    local value=${!name:-}

    [[ "$value" =~ ^[0-9]+$ ]] || backup_die "$name must be an integer"
}

backup_require_unprivileged_runtime_identity() {
    local actual_home
    local actual_uid

    getent passwd "$HERMES_USER" >/dev/null || backup_die "Hermes user is missing: $HERMES_USER"
    actual_home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
    [[ "$actual_home" == "$HERMES_HOME" ]] \
        || backup_die "HERMES_HOME does not match the account home: $actual_home"
    actual_uid=$(id -u "$HERMES_USER")
    [[ "$actual_uid" != 0 ]] \
        || backup_die 'HERMES_USER must identify an unprivileged account'
}

backup_require_runtime_identity() {
    backup_require_unprivileged_runtime_identity

    [[ -d "$HERMES_HOME/.hermes" ]] || backup_die 'Hermes state directory is missing'
    [[ "$(stat -c '%U:%G' "$HERMES_HOME/.hermes")" == "$HERMES_USER:$HERMES_USER" ]] \
        || backup_die 'Hermes state directory ownership is unexpected'
}

backup_require_sensitive_file() {
    local path=$1
    local mode

    [[ ! -L "$path" && -f "$path" ]] || backup_die "required state file is missing or symlinked: $path"
    [[ "$(stat -c '%U:%G' "$path")" == "$HERMES_USER:$HERMES_USER" ]] \
        || backup_die "state file ownership is unexpected: $path"
    mode=$(stat -c '%a' "$path")
    (( (8#$mode & 077) == 0 )) || backup_die "sensitive state file is group/world accessible: $path"
}

backup_require_state_file() {
    local path=$1

    [[ ! -L "$path" && -f "$path" ]] || backup_die "required state file is missing or symlinked: $path"
    [[ "$(stat -c '%U:%G' "$path")" == "$HERMES_USER:$HERMES_USER" ]] \
        || backup_die "state file ownership is unexpected: $path"
}

backup_require_state_directory() {
    local path=$1

    [[ ! -L "$path" && -d "$path" ]] || backup_die "required state directory is missing or symlinked: $path"
    [[ "$(stat -c '%U:%G' "$path")" == "$HERMES_USER:$HERMES_USER" ]] \
        || backup_die "state directory ownership is unexpected: $path"
}

backup_validate_configuration() {
    backup_require_root
    backup_require_runtime_identity
    backup_require_sensitive_file "$HERMES_HOME/.hermes/.env"
    backup_require_sensitive_file "$HERMES_HOME/.hermes/auth.json"
    backup_require_sensitive_file "$HERMES_HOME/.hermes/config.yaml"
    backup_require_state_file "$HERMES_HOME/.hermes/SOUL.md"

    for database in \
        "$HERMES_HOME/.hermes/state.db" \
        "$HERMES_HOME/.hermes/kanban.db" \
        "$HERMES_HOME/.hermes/cron/executions.db"; do
        backup_require_state_file "$database"
    done

    backup_require_state_directory "$HERMES_HOME/.hermes/pairing"
    backup_require_state_directory "$HERMES_HOME/.hermes/state"
    backup_require_state_directory "$HERMES_HOME/.hermes/kanban"
    backup_require_state_directory "$HERMES_HOME/.hermes/cron"

    if [[ "$INCLUDE_SESSION_HISTORY" == true ]]; then
        backup_require_state_directory "$HERMES_HOME/.hermes/sessions"
    fi

    if [[ "$INCLUDE_USER_MEMORIES" == true ]]; then
        backup_require_state_directory "$HERMES_HOME/.hermes/memories"
    fi
    if [[ "$INCLUDE_CHROMIUM_PROFILE" == true ]]; then
        backup_require_state_directory "$HERMES_HOME/.local/share/hermes/chromium-profile"
        [[ "$(stat -c '%U:%G' "$HERMES_HOME/.local/share/hermes/chromium-profile")" \
            == "$HERMES_USER:$HERMES_USER" ]] \
            || backup_die 'Chromium profile ownership is unexpected'
    fi
}

backup_validate_runtime_options() {
    backup_require_bool INCLUDE_CHROMIUM_PROFILE
    backup_require_bool INCLUDE_SESSION_HISTORY
    backup_require_bool INCLUDE_USER_MEMORIES
    backup_require_bool APPLY_RETENTION
    backup_require_integer KEEP_DAILY
    backup_require_integer KEEP_WEEKLY
    backup_require_integer KEEP_MONTHLY
    (( KEEP_DAILY > 0 && KEEP_WEEKLY > 0 && KEEP_MONTHLY > 0 )) \
        || backup_die 'retention counts must be greater than zero'
}

backup_require_off_host_destination() {
    [[ "$BACKUP_DESTINATION_KIND" == off-host ]] \
        || backup_die 'BACKUP_DESTINATION_KIND must be explicitly set to off-host'
    [[ -n "$BACKUP_REPOSITORY" ]] || backup_die 'BACKUP_REPOSITORY is required'
    case "$BACKUP_REPOSITORY" in
        /*|file:*|local:*)
            backup_die 'off-host backups must use a remote restic repository form'
            ;;
    esac
}

backup_require_secure_password_file() {
    [[ -n "$BACKUP_PASSWORD_FILE" ]] || backup_die 'BACKUP_PASSWORD_FILE is required'
    [[ "$BACKUP_PASSWORD_FILE" == /* ]] || backup_die 'BACKUP_PASSWORD_FILE must be absolute'
    [[ ! -L "$BACKUP_PASSWORD_FILE" && -f "$BACKUP_PASSWORD_FILE" ]] \
        || backup_die 'backup password file must be a regular non-symlink file'
    [[ "$(stat -c '%u:%a' "$BACKUP_PASSWORD_FILE")" == '0:600' ]] \
        || backup_die 'backup password file must be root-owned with mode 0600'
    [[ "$BACKUP_PASSWORD_FILE" != "$HERMES_HOME"/* ]] \
        || backup_die 'backup password file must not be under HERMES_HOME'
}

backup_validate_restore_target() {
    local target=$1

    [[ "$target" == /* ]] || backup_die '--target must be absolute'
    [[ "$target" == /var/tmp/hermes-restore-test-* ]] \
        || backup_die '--target must match /var/tmp/hermes-restore-test-*'
    [[ "$(dirname -- "$target")" == /var/tmp ]] \
        || backup_die 'restore target must be a direct /var/tmp child'
    [[ "$target" != /var/tmp/hermes-restore-test- ]] \
        || backup_die 'restore target must have a unique suffix'
    [[ "$target" != "$HERMES_HOME" && "$target" != "$HERMES_HOME"/* ]] \
        || backup_die 'refusing to restore over or below HERMES_HOME'
    [[ ! -e "$target" ]] || backup_die 'restore target already exists'
    [[ -d /var/tmp && "$(stat -c '%u' /var/tmp)" == 0 ]] \
        || backup_die 'restore target parent must be root-owned'
}

backup_normalize_restored_runtime_ownership() {
    local restore_root=$1
    local restored_home="$restore_root$HERMES_HOME"

    [[ -d "$restored_home" && ! -L "$restored_home" ]] \
        || backup_die 'restored Hermes home is missing or symlinked'
    chown -R --no-dereference -- "$HERMES_USER:$HERMES_USER" "$restored_home" \
        || backup_die 'could not normalize restored Hermes ownership'
}

backup_restic() {
    RESTIC_REPOSITORY="$BACKUP_REPOSITORY" \
        RESTIC_PASSWORD_FILE="$BACKUP_PASSWORD_FILE" \
        "$RESTIC_BIN" "$@"
}

backup_json_number() {
    local key=$1
    local json_file=$2

    sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p" "$json_file" \
        | tail -n 1
}

backup_append_path() {
    local manifest_file=$1
    local path=$2

    [[ -e "$path" ]] || backup_die "manifest path is missing: $path"
    [[ ! -L "$path" ]] || backup_die "manifest path must not be a symlink: $path"
    printf '%s\n' "$path" >>"$manifest_file"
}

backup_append_database_family() {
    local manifest_file=$1
    local database=$2

    backup_append_path "$manifest_file" "$database"
    for companion in "$database-wal" "$database-shm"; do
        if [[ -e "$companion" ]]; then
            backup_append_path "$manifest_file" "$companion"
        fi
    done
}

backup_build_manifest() {
    local manifest_file=$1

    : >"$manifest_file"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/.env"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/auth.json"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/config.yaml"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/SOUL.md"
    backup_append_database_family "$manifest_file" "$HERMES_HOME/.hermes/state.db"
    backup_append_database_family "$manifest_file" "$HERMES_HOME/.hermes/kanban.db"
    backup_append_database_family "$manifest_file" "$HERMES_HOME/.hermes/cron/executions.db"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/pairing"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/state"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/kanban"
    backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/cron"

    if [[ "$INCLUDE_SESSION_HISTORY" == true ]]; then
        backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/sessions"
    fi
    if [[ "$INCLUDE_USER_MEMORIES" == true ]]; then
        backup_append_path "$manifest_file" "$HERMES_HOME/.hermes/memories"
    fi
    if [[ "$INCLUDE_CHROMIUM_PROFILE" == true ]]; then
        backup_append_path "$manifest_file" "$HERMES_HOME/.local/share/hermes/chromium-profile"
    fi
}

backup_write_metadata() {
    local metadata_file=$1
    local manifest_file=$2
    local hermes_version='unavailable'
    local source_commit='unavailable'
    local cua_version='unavailable'
    local chromium_version='unavailable'
    local debian_version='unavailable'
    local restic_version='unavailable'
    local path

    if [[ -x "$HERMES_HOME/.local/bin/hermes" ]]; then
        hermes_version=$(runuser -u "$HERMES_USER" -- env \
            HOME="$HERMES_HOME" \
            PATH="$HERMES_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
            "$HERMES_HOME/.local/bin/hermes" --version | sed -n '1p')
    fi
    if [[ -d "$HERMES_HOME/.hermes/hermes-agent/.git" ]]; then
        source_commit=$(git -C "$HERMES_HOME/.hermes/hermes-agent" rev-parse HEAD)
    fi
    if [[ -x "$HERMES_HOME/.local/bin/cua-driver" ]]; then
        cua_version=$(runuser -u "$HERMES_USER" -- env \
            HOME="$HERMES_HOME" \
            PATH="$HERMES_HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
            "$HERMES_HOME/.local/bin/cua-driver" --version | sed -n '1p')
    fi
    if [[ -x /usr/bin/chromium ]]; then
        chromium_version=$(/usr/bin/chromium --version | sed -n '1p')
    fi
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        debian_version=${VERSION_ID:-unavailable}
    fi
    if command -v "$RESTIC_BIN" >/dev/null 2>&1; then
        restic_version=$("$RESTIC_BIN" version | sed -n '1p')
    fi

    umask 077
    {
        printf 'format=hermes-state-restic-v1\n'
        printf 'hermes_version=%s\n' "$hermes_version"
        printf 'hermes_source_commit=%s\n' "$source_commit"
        printf 'cua_driver_version=%s\n' "$cua_version"
        printf 'chromium_version=%s\n' "$chromium_version"
        printf 'debian_version=%s\n' "$debian_version"
        printf 'restic_version=%s\n' "$restic_version"
        while IFS= read -r path; do
            printf 'included_path=%s\n' "$path"
        done <"$manifest_file"
        printf '%s\n' 'excluded=Hermes source checkout and virtual environment'
        printf '%s\n' 'excluded=Playwright/browser caches and browser cache subtrees'
        printf '%s\n' 'excluded=generic logs, gateway locks/PIDs, cron output, ticker files'
    } >"$metadata_file"
}

backup_sqlite_quick_check() {
    local database=$1

    /usr/bin/python3 - "$database" <<'PY'
import sqlite3
import sys

path = sys.argv[1]
connection = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
try:
    result = connection.execute("PRAGMA quick_check").fetchone()[0]
    if result != "ok":
        raise SystemExit(1)
finally:
    connection.close()
PY
}

backup_validate_restored_tree() {
    local restore_root=$1
    local restored_home="$restore_root$HERMES_HOME"
    local hermes_uid
    local hermes_gid
    local path
    local mode
    local yaml_python=${HERMES_PYTHON:-$HERMES_HOME/.hermes/hermes-agent/venv/bin/python}

    [[ -d "$restored_home/.hermes" ]] || backup_die 'restored Hermes state directory is missing'
    hermes_uid=$(id -u "$HERMES_USER")
    hermes_gid=$(id -g "$HERMES_USER")
    [[ "$(stat -c '%u:%g' "$restored_home/.hermes")" == "$hermes_uid:$hermes_gid" ]] \
        || backup_die 'restored Hermes state directory ownership is unexpected'

    for path in \
        "$restored_home/.hermes/.env" \
        "$restored_home/.hermes/auth.json" \
        "$restored_home/.hermes/config.yaml"; do
        [[ -f "$path" && ! -L "$path" ]] || backup_die "restored sensitive file is missing: $path"
        [[ "$(stat -c '%u:%g' "$path")" == "$hermes_uid:$hermes_gid" ]] \
            || backup_die "restored sensitive file ownership is unexpected: $path"
        mode=$(stat -c '%a' "$path")
        (( (8#$mode & 077) == 0 )) || backup_die "restored sensitive file permissions are unsafe: $path"
    done

    path="$restored_home/.hermes/SOUL.md"
    [[ -f "$path" && ! -L "$path" ]] || backup_die 'restored SOUL.md is missing'
    [[ "$(stat -c '%u:%g' "$path")" == "$hermes_uid:$hermes_gid" ]] \
        || backup_die 'restored SOUL.md ownership is unexpected'

    for path in \
        "$restored_home/.hermes/state.db" \
        "$restored_home/.hermes/kanban.db" \
        "$restored_home/.hermes/cron/executions.db"; do
        [[ -f "$path" ]] || backup_die "restored database is missing: $path"
        [[ "$(stat -c '%u:%g' "$path")" == "$hermes_uid:$hermes_gid" ]] \
            || backup_die "restored database ownership is unexpected: $path"
        backup_sqlite_quick_check "$path" || backup_die "restored SQLite quick_check failed: $path"
    done

    [[ -x "$yaml_python" ]] || backup_die "YAML validation Python is unavailable: $yaml_python"
    "$yaml_python" - "$restored_home/.hermes/config.yaml" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    yaml.safe_load(stream)
PY

    for path in \
        "$restored_home/.hermes/pairing" \
        "$restored_home/.hermes/state" \
        "$restored_home/.hermes/kanban" \
        "$restored_home/.hermes/cron"; do
        [[ -d "$path" ]] || backup_die "restored state directory is missing: $path"
        [[ "$(stat -c '%u:%g' "$path")" == "$hermes_uid:$hermes_gid" ]] \
            || backup_die "restored state directory ownership is unexpected: $path"
    done
    if find "$restored_home/.hermes/pairing" -xdev -type f -perm /007 -print -quit | grep -q .; then
        backup_die 'restored pairing files contain group/world-readable files'
    fi

    if [[ "$INCLUDE_SESSION_HISTORY" == true ]]; then
        [[ -d "$restored_home/.hermes/sessions" ]] \
            || backup_die 'restored session history is missing'
    fi
    if [[ "$INCLUDE_USER_MEMORIES" == true ]]; then
        [[ -d "$restored_home/.hermes/memories" ]] \
            || backup_die 'restored memories directory is missing'
    fi
    if [[ "$INCLUDE_CHROMIUM_PROFILE" == true ]]; then
        local profile="$restored_home/.local/share/hermes/chromium-profile"
        [[ -d "$profile" && -f "$profile/Local State" && -d "$profile/Default" ]] \
            || backup_die 'restored Chromium profile structure is incomplete'
        [[ "$(stat -c '%u:%g' "$profile")" == "$hermes_uid:$hermes_gid" ]] \
            || backup_die 'restored Chromium profile ownership is unexpected'
        if find "$profile" -xdev -type f -perm /007 -print -quit | grep -q .; then
            backup_die 'restored Chromium profile contains group/world-readable files'
        fi
    fi

    printf '%s\n' 'isolated restore validation passed.'
}
