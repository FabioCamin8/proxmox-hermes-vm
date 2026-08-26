#!/usr/bin/env bash

set -Eeuo pipefail

script_name=${BASH_SOURCE[0]##*/}
stage_arg=
env_file=

usage() {
    cat <<'EOF'
Usage: harden-guest.sh [--env FILE] [--stage STAGE]

Stages:
  operator  Create the separate operator account and install its public key.
  privilege Remove Hermes sudo access; run this through a fresh operator SSH session.
  network   Disable LLMNR and optionally apply a live nftables policy with rollback.
  adopt     Record ownership of an already-loaded, repository-matching firewall.
  finalize  Persist a successfully tested live nftables policy and cancel rollback.

Run each stage with explicit environment values. The firewall is opt-in.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

while (($# > 0)); do
    case $1 in
        --env)
            (($# >= 2)) || die '--env requires a file'
            env_file=$2
            shift 2
            ;;
        --stage)
            (($# >= 2)) || die '--stage requires a value'
            stage_arg=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [[ -n "$env_file" ]]; then
    [[ -r "$env_file" ]] || die "environment file is not readable: $env_file"
    # shellcheck disable=SC1090
    source "$env_file"
fi

stage=${STAGE:-operator}
[[ -z "$stage_arg" ]] || stage=$stage_arg

HERMES_USER=${HERMES_USER:-hermes}
ADMIN_USER=${ADMIN_USER:-ops}
ADMIN_SSH_PUBLIC_KEY_FILE=${ADMIN_SSH_PUBLIC_KEY_FILE:-}
ENABLE_LLMNR=${ENABLE_LLMNR:-false}
ENABLE_FIREWALL=${ENABLE_FIREWALL:-false}
SSH_ALLOWED_CIDR=${SSH_ALLOWED_CIDR:-}
SSH_ALLOWED_IPV6_CIDR=${SSH_ALLOWED_IPV6_CIDR:-}
FIREWALL_ROLLBACK_SECONDS=${FIREWALL_ROLLBACK_SECONDS:-120}

require_bool() {
    local name=$1
    local value=$2
    [[ "$value" == true || "$value" == false ]] || die "$name must be true or false"
}

require_account_name() {
    local name=$1
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid account name: $name"
}

require_root() {
    [[ "$(id -u)" == 0 ]] || die "run $script_name as root, normally through sudo"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_bool ENABLE_LLMNR "$ENABLE_LLMNR"
require_bool ENABLE_FIREWALL "$ENABLE_FIREWALL"
require_account_name "$HERMES_USER"
require_account_name "$ADMIN_USER"
[[ "$HERMES_USER" != "$ADMIN_USER" ]] || die 'HERMES_USER and ADMIN_USER must differ'
[[ "$FIREWALL_ROLLBACK_SECONDS" =~ ^[0-9]+$ ]] || die 'FIREWALL_ROLLBACK_SECONDS must be an integer'
((FIREWALL_ROLLBACK_SECONDS >= 30 && FIREWALL_ROLLBACK_SECONDS <= 600)) \
    || die 'FIREWALL_ROLLBACK_SECONDS must be between 30 and 600 seconds'

state_dir=${HERMES_HARDENING_STATE_DIR:-/var/lib/hermes-hardening}
runtime_dir=${HERMES_HARDENING_RUNTIME_DIR:-/run/hermes-hardening}
admin_marker=$state_dir/admin-user
operator_sudoers=/etc/sudoers.d/90-hermes-operator
resolved_dropin=${HERMES_RESOLVED_DROPIN:-/etc/systemd/resolved.conf.d/99-hermes-hardening.conf}
nftables_config=${HERMES_NFTABLES_CONFIG:-/etc/nftables.conf}
managed_marker=$state_dir/nftables-managed
rollback_unit=hermes-firewall-rollback.service
candidate_file=$runtime_dir/nftables.candidate
before_file=$runtime_dir/nftables.before
rollback_file=$runtime_dir/nftables.rollback
live_file=$runtime_dir/nftables.live
pending_marker=$runtime_dir/nftables.pending

operator_key_check() {
    [[ -n "$ADMIN_SSH_PUBLIC_KEY_FILE" ]] || die 'ADMIN_SSH_PUBLIC_KEY_FILE is required for the operator stage'
    [[ -r "$ADMIN_SSH_PUBLIC_KEY_FILE" ]] || die "public key file is not readable: $ADMIN_SSH_PUBLIC_KEY_FILE"
    ! grep -q 'PRIVATE KEY' "$ADMIN_SSH_PUBLIC_KEY_FILE" \
        || die 'ADMIN_SSH_PUBLIC_KEY_FILE appears to contain a private key'
    require_command ssh-keygen
    ssh-keygen -lf "$ADMIN_SSH_PUBLIC_KEY_FILE" >/dev/null 2>&1 \
        || die 'ADMIN_SSH_PUBLIC_KEY_FILE is not a valid public key file'
}

operator_policy_check() {
    getent passwd "$ADMIN_USER" >/dev/null || die "operator account is missing: $ADMIN_USER"
    runuser -u "$ADMIN_USER" -- sudo -n true \
        || die "operator sudo policy is not usable for $ADMIN_USER"
}

stage_operator() {
    require_root
    require_command getent
    require_command useradd
    require_command usermod
    require_command passwd
    require_command install
    require_command visudo
    operator_key_check

    install -d -m 0700 "$state_dir"
    if getent passwd "$ADMIN_USER" >/dev/null; then
        [[ -r "$admin_marker" && "$(<"$admin_marker")" == "$ADMIN_USER" ]] \
            || die "$ADMIN_USER already exists; choose another ADMIN_USER or explicitly review it"
    else
        useradd --create-home --shell /bin/bash "$ADMIN_USER"
        printf '%s\n' "$ADMIN_USER" >"$admin_marker"
        chmod 0600 "$admin_marker"
    fi

    usermod --append --groups sudo "$ADMIN_USER"
    passwd --lock "$ADMIN_USER" >/dev/null

    operator_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    [[ -n "$operator_home" && -d "$operator_home" ]] || die 'operator home directory is unavailable'
    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0700 "$operator_home/.ssh"
    install -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0600 \
        "$ADMIN_SSH_PUBLIC_KEY_FILE" "$operator_home/.ssh/authorized_keys"

    operator_rule="$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"
    if [[ -e "$operator_sudoers" ]]; then
        grep -Fxq "$operator_rule" "$operator_sudoers" \
            || die "refusing to overwrite existing $operator_sudoers"
    else
        install -m 0440 /dev/null "$operator_sudoers"
        printf '%s\n' "$operator_rule" >"$operator_sudoers"
        chown root:root "$operator_sudoers"
        chmod 0440 "$operator_sudoers"
    fi

    visudo -c >/dev/null
    operator_policy_check
    printf '%s\n' 'operator stage complete; prove a fresh SSH session before the privilege stage.'
}

require_operator_session() {
    require_root
    [[ "${SUDO_USER:-}" == "$ADMIN_USER" ]] \
        || die "run this stage through sudo from a fresh $ADMIN_USER SSH session"
    operator_policy_check
}

remove_hermes_direct_sudo_rules() {
    local file tmp mode
    while IFS= read -r -d '' file; do
        if awk -v user="$HERMES_USER" '
            /^[[:space:]]*#/ { next }
            {
                token = $0
                sub(/^[[:space:]]*/, "", token)
                sub(/[[:space:]].*$/, "", token)
                if (token == user) { found = 1 }
            }
            END { exit(found ? 0 : 1) }
        ' "$file"; then
            tmp=$(mktemp)
            awk -v user="$HERMES_USER" '
                /^[[:space:]]*#/ { print; next }
                {
                    token = $0
                    sub(/^[[:space:]]*/, "", token)
                    sub(/[[:space:]].*$/, "", token)
                    if (token != user) { print }
                }
            ' "$file" >"$tmp"
            mode=$(stat -c '%a' "$file")
            install -o root -g root -m "$mode" "$tmp" "$file"
            rm -f "$tmp"
        fi
    done < <(find /etc/sudoers /etc/sudoers.d -maxdepth 1 -type f -print0)
}

stage_privilege() {
    require_operator_session
    require_command gpasswd
    require_command visudo
    require_command runuser

    visudo -c >/dev/null
    remove_hermes_direct_sudo_rules
    gpasswd --delete "$HERMES_USER" sudo >/dev/null 2>&1 || true
    visudo -c >/dev/null

    if runuser -u "$HERMES_USER" -- sudo -n true >/dev/null 2>&1; then
        die "$HERMES_USER still has non-interactive sudo access"
    fi
    printf '%s\n' 'privilege stage complete; Hermes no longer has a sudo escalation path.'
}

write_resolved_policy() {
    install -d -m 0755 /etc/systemd/resolved.conf.d
    install -m 0644 /dev/null "$resolved_dropin"
    printf '%s\n' '[Resolve]' 'LLMNR=no' >"$resolved_dropin"
}

stage_llmnr() {
    require_command systemctl
    require_command resolvectl
    if [[ "$ENABLE_LLMNR" == false ]]; then
        write_resolved_policy
    else
        rm -f "$resolved_dropin"
    fi
    systemctl restart systemd-resolved
}

ensure_nftables() {
    if ! command -v nft >/dev/null 2>&1; then
        require_command apt-get
        env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nftables
    fi
    require_command nft
}

validate_ipv4_cidr() {
    local value=$1
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
        || die "invalid IPv4 SSH_ALLOWED_CIDR: $value"
}

validate_ipv6_cidr() {
    local value=$1
    [[ "$value" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
        || die "invalid IPv6 SSH_ALLOWED_IPV6_CIDR: $value"
}

append_ssh_rule() {
    local value=$1
    if [[ "$value" == *:* ]]; then
        validate_ipv6_cidr "$value"
        printf '        ip6 saddr %s tcp dport 22 ct state new accept\n' "$value"
    else
        validate_ipv4_cidr "$value"
        printf '        ip saddr %s tcp dport 22 ct state new accept\n' "$value"
    fi
}

render_firewall() {
    [[ -n "$SSH_ALLOWED_CIDR" || -n "$SSH_ALLOWED_IPV6_CIDR" ]] \
        || die 'firewall requires SSH_ALLOWED_CIDR or SSH_ALLOWED_IPV6_CIDR'
    require_command nft
    install -d -m 0700 "$runtime_dir"
    {
        printf '%s\n' 'flush ruleset' 'table inet hermes_guest {'
        printf '%s\n' '    chain input {'
        printf '%s\n' '        type filter hook input priority 0; policy drop;'
        printf '%s\n' '        iifname "lo" accept'
        printf '%s\n' '        ct state established,related accept'
        printf '%s\n' '        ct state invalid drop'
        printf '%s\n' '        udp sport 67 udp dport 68 accept'
        printf '%s\n' '        icmp type { destination-unreachable, echo-request, echo-reply, time-exceeded, parameter-problem } accept'
        printf '%s\n' '        icmpv6 type { destination-unreachable, packet-too-big, time-exceeded, parameter-problem, echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert, nd-redirect } accept'
        [[ -z "$SSH_ALLOWED_CIDR" ]] || append_ssh_rule "$SSH_ALLOWED_CIDR"
        [[ -z "$SSH_ALLOWED_IPV6_CIDR" ]] || append_ssh_rule "$SSH_ALLOWED_IPV6_CIDR"
        printf '%s\n' '    }' '    chain forward {'
        printf '%s\n' '        type filter hook forward priority 0; policy drop;'
        printf '%s\n' '    }' '    chain output {'
        printf '%s\n' '        type filter hook output priority 0; policy accept;'
        printf '%s\n' '    }' '}'
    } >"$candidate_file"
    nft -c -f "$candidate_file"
}

file_is_root_owned_regular() {
    local file=$1 metadata
    [[ -f "$file" && ! -L "$file" ]] || return 1
    metadata=$(stat -c '%u:%g' "$file") || return 1
    [[ "$metadata" == 0:0 ]]
}

file_has_meaningful_content() {
    local file=$1
    awk '
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*#!/ { next }
        { found = 1; exit }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

nftables_config_is_takeover_safe() {
    if [[ ! -e "$nftables_config" && ! -L "$nftables_config" ]]; then
        return 0
    fi
    file_is_root_owned_regular "$nftables_config" || return 1
    ! file_has_meaningful_content "$nftables_config"
}

firewall_config_preflight() {
    if ! command -v nft >/dev/null 2>&1 \
        && [[ -e "$nftables_config" || -L "$nftables_config" ]] \
        && ! nftables_config_is_takeover_safe; then
        die "nft is unavailable and an existing nftables configuration is not known-safe; refusing package installation before reviewing $nftables_config"
    fi
}

canonicalize_firewall_file() {
    local file=$1
    awk '
        /^[[:space:]]*flush ruleset[[:space:]]*$/ { next }
        /^[[:space:]]*$/ { print ""; next }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            gsub(/priority filter/, "priority 0", line)
            print line
        }
    ' "$file"
}

live_firewall_matches_candidate() {
    local expected_file actual_file
    expected_file=$(mktemp)
    actual_file=$(mktemp)
    if ! canonicalize_firewall_file "$candidate_file" >"$expected_file"; then
        rm -f "$expected_file" "$actual_file"
        return 1
    fi
    if ! canonicalize_firewall_file "$live_file" >"$actual_file"; then
        rm -f "$expected_file" "$actual_file"
        return 1
    fi
    if ! cmp -s "$expected_file" "$actual_file"; then
        rm -f "$expected_file" "$actual_file"
        return 1
    fi
    rm -f "$expected_file" "$actual_file"
}

capture_live_firewall() {
    require_command nft
    install -d -m 0700 "$runtime_dir"
    install -m 0600 /dev/null "$live_file"
    nft list ruleset >"$live_file" \
        || die 'unable to inspect the current nftables ruleset'
}

file_sha256() {
    local digest
    read -r digest _ < <(sha256sum -- "$1")
    printf '%s\n' "$digest"
}

managed_marker_is_trusted() {
    file_is_root_owned_regular "$managed_marker" || return 1
    metadata=$(stat -c '%a' "$managed_marker") || return 1
    [[ "$metadata" == 600 ]] || return 1
    [[ "$(sed -n '1p' "$managed_marker")" == 'version=1' ]] || return 1
    [[ "$(wc -l <"$managed_marker")" == 4 ]] || return 1
}

managed_state_matches() {
    local candidate_digest config_digest live_digest marker_candidate marker_config marker_live
    managed_marker_is_trusted || return 1
    file_is_root_owned_regular "$nftables_config" || return 1
    cmp -s "$candidate_file" "$nftables_config" || return 1
    live_firewall_matches_candidate || return 1

    marker_candidate=$(sed -n '2p' "$managed_marker")
    marker_config=$(sed -n '3p' "$managed_marker")
    marker_live=$(sed -n '4p' "$managed_marker")
    [[ "$marker_candidate" == candidate_sha256=* ]] || return 1
    [[ "$marker_config" == config_sha256=* ]] || return 1
    [[ "$marker_live" == live_sha256=* ]] || return 1
    candidate_digest=${marker_candidate#candidate_sha256=}
    config_digest=${marker_config#config_sha256=}
    live_digest=${marker_live#live_sha256=}
    [[ "$candidate_digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    [[ "$config_digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    [[ "$live_digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
    [[ "$candidate_digest" == "$(file_sha256 "$candidate_file")" ]] || return 1
    [[ "$config_digest" == "$(file_sha256 "$nftables_config")" ]] || return 1
    [[ "$live_digest" == "$(file_sha256 "$live_file")" ]]
}

write_managed_marker() {
    local temporary candidate_digest config_digest live_digest
    require_command sha256sum
    install -d -o root -g root -m 0700 "$state_dir"
    [[ ! -L "$managed_marker" ]] \
        || die "refusing to replace symlinked managed state: $managed_marker"
    candidate_digest=$(file_sha256 "$candidate_file")
    config_digest=$(file_sha256 "$nftables_config")
    live_digest=$(file_sha256 "$live_file")
    temporary=$(mktemp "$state_dir/.nftables-managed.XXXXXX")
    {
        printf '%s\n' 'version=1'
        printf 'candidate_sha256=%s\n' "$candidate_digest"
        printf 'config_sha256=%s\n' "$config_digest"
        printf 'live_sha256=%s\n' "$live_digest"
    } >"$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$managed_marker"
}

write_pending_marker() {
    local temporary candidate_digest before_digest
    require_command sha256sum
    [[ ! -L "$pending_marker" ]] \
        || die "refusing to replace symlinked pending state: $pending_marker"
    candidate_digest=$(file_sha256 "$candidate_file")
    before_digest=$(file_sha256 "$before_file")
    temporary=$(mktemp "$runtime_dir/.nftables-pending.XXXXXX")
    {
        printf '%s\n' 'version=1'
        printf 'candidate_sha256=%s\n' "$candidate_digest"
        printf 'before_sha256=%s\n' "$before_digest"
    } >"$temporary"
    chown root:root "$temporary"
    chmod 0600 "$temporary"
    mv -f -- "$temporary" "$pending_marker"
}

pending_state_is_valid() {
    local candidate_digest before_digest marker_candidate marker_before
    file_is_root_owned_regular "$pending_marker" || return 1
    [[ "$(stat -c '%a' "$pending_marker")" == 600 ]] || return 1
    [[ "$(wc -l <"$pending_marker")" == 3 ]] || return 1
    marker_candidate=$(sed -n '2p' "$pending_marker")
    marker_before=$(sed -n '3p' "$pending_marker")
    [[ "$marker_candidate" == candidate_sha256=* ]] || return 1
    [[ "$marker_before" == before_sha256=* ]] || return 1
    candidate_digest=${marker_candidate#candidate_sha256=}
    before_digest=${marker_before#before_sha256=}
    [[ "$candidate_digest" == "$(file_sha256 "$candidate_file")" ]] || return 1
    [[ "$before_digest" == "$(file_sha256 "$before_file")" ]] || return 1
    ! file_has_meaningful_content "$before_file"
}

inspect_firewall_state() {
    capture_live_firewall
    if file_has_meaningful_content "$live_file"; then
        if managed_state_matches; then
            firewall_state=managed
            return 0
        fi
        die 'unmanaged or ambiguous nftables rules are loaded; refusing to flush or replace them (use --stage adopt only after reviewing the live policy)'
    fi
    [[ ! -e "$managed_marker" && ! -L "$managed_marker" ]] \
        || die 'managed nftables state exists but the live ruleset is empty; refusing ambiguous ownership'
    nftables_config_is_takeover_safe \
        || die "an existing nftables configuration is not repository-owned or empty; refusing to overwrite $nftables_config"
    firewall_state=clean
}

stage_firewall_live() {
    require_command nft
    require_command systemd-run
    require_command systemctl
    render_firewall
    inspect_firewall_state
    if [[ "$firewall_state" == managed ]]; then
        printf '%s\n' 'firewall already matches the repository-managed policy; no live nftables change was needed.'
        return 0
    fi
    install -m 0600 "$live_file" "$before_file"
    install -m 0600 /dev/null "$rollback_file"
    if file_has_meaningful_content "$before_file"; then
        install -m 0600 "$before_file" "$rollback_file"
    else
        printf '%s\n' 'flush ruleset' >"$rollback_file"
    fi
    write_pending_marker
    systemctl stop "$rollback_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$rollback_unit" >/dev/null 2>&1 || true
    systemd-run --unit="$rollback_unit" --on-active="${FIREWALL_ROLLBACK_SECONDS}s" --collect \
        /usr/sbin/nft -f "$rollback_file" >/dev/null
    nft -f "$candidate_file"
    printf '%s\n' \
        'firewall live policy applied; a rollback timer is active.' \
        "rollback_unit=$rollback_unit" \
        "rollback_seconds=$FIREWALL_ROLLBACK_SECONDS" \
        'Run a fresh operator SSH test, then run --stage finalize.'
}

stage_network() {
    require_operator_session
    if [[ "$ENABLE_FIREWALL" == true ]]; then
        firewall_config_preflight
        ensure_nftables
        require_command systemd-run
    fi
    stage_llmnr
    printf 'llmnr=%s\n' "$([[ "$ENABLE_LLMNR" == false ]] && printf disabled || printf enabled)"
    if [[ "$ENABLE_FIREWALL" == true ]]; then
        stage_firewall_live
    else
        printf '%s\n' 'firewall=disabled (set ENABLE_FIREWALL=true with an explicit SSH range to apply it)'
    fi
}

stage_finalize() {
    require_operator_session
    [[ "$ENABLE_FIREWALL" == true ]] || {
        printf '%s\n' 'firewall=disabled; nothing to persist.'
        return 0
    }
    [[ -r "$candidate_file" ]] || die 'live firewall candidate is missing; run --stage network first'
    require_command nft
    require_command systemctl
    require_command sha256sum
    nft -c -f "$candidate_file"
    capture_live_firewall
    live_firewall_matches_candidate \
        || die 'the live nftables rules do not match the staged repository policy; refusing persistence'

    if managed_state_matches; then
        systemctl stop "$rollback_unit" >/dev/null 2>&1 || true
        systemctl reset-failed "$rollback_unit" >/dev/null 2>&1 || true
        rm -f "$candidate_file" "$before_file" "$rollback_file" "$live_file" "$pending_marker"
        printf '%s\n' 'firewall is already persisted under repository ownership; rollback timer cancelled after the fresh operator session.'
        return 0
    fi

    pending_state_is_valid \
        || die 'the live policy is not a staged clean-firewall change; use --stage network first or review the guest manually'
    nftables_config_is_takeover_safe \
        || die "refusing to overwrite an unmanaged nftables configuration: $nftables_config"
    install -m 0644 "$candidate_file" "$nftables_config"
    nft -c -f "$nftables_config"
    systemctl enable nftables >/dev/null
    systemctl restart nftables
    systemctl is-active --quiet nftables || die 'nftables service is not active after persistence'
    capture_live_firewall
    live_firewall_matches_candidate \
        || die 'the persisted nftables policy does not match the repository policy'
    cmp -s "$candidate_file" "$nftables_config" \
        || die 'the persisted nftables configuration changed unexpectedly'
    write_managed_marker
    systemctl stop "$rollback_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$rollback_unit" >/dev/null 2>&1 || true
    rm -f "$candidate_file" "$before_file" "$rollback_file" "$live_file" "$pending_marker"
    printf '%s\n' 'firewall persistence complete; rollback timer cancelled after the fresh operator session.'
}

stage_adopt() {
    require_operator_session
    [[ "$ENABLE_FIREWALL" == true ]] \
        || die 'set ENABLE_FIREWALL=true before adopting a firewall policy'
    require_command nft
    require_command systemctl
    require_command sha256sum
    render_firewall
    capture_live_firewall
    file_has_meaningful_content "$live_file" \
        || die 'cannot adopt an empty nftables ruleset'
    live_firewall_matches_candidate \
        || die 'the live nftables rules do not exactly match the repository-generated policy; refusing adoption'
    file_is_root_owned_regular "$nftables_config" \
        || die "the nftables configuration is not a root-owned regular file: $nftables_config"
    cmp -s "$candidate_file" "$nftables_config" \
        || die "the nftables configuration does not match the repository policy; refusing adoption"
    nft -c -f "$nftables_config"
    systemctl is-active --quiet nftables \
        || die 'nftables service is not active; refusing adoption'
    write_managed_marker
    rm -f "$candidate_file" "$live_file"
    printf '%s\n' 'firewall ownership adopted after live ruleset and persistent configuration proof; nftables was not reapplied.'
}

case "$stage" in
    operator) stage_operator ;;
    privilege) stage_privilege ;;
    network) stage_network ;;
    adopt) stage_adopt ;;
    finalize) stage_finalize ;;
    *) die "unknown stage: $stage" ;;
esac
