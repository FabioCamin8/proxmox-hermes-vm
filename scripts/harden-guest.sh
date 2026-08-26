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

state_dir=/var/lib/hermes-hardening
runtime_dir=/run/hermes-hardening
admin_marker=$state_dir/admin-user
operator_sudoers=/etc/sudoers.d/90-hermes-operator
resolved_dropin=/etc/systemd/resolved.conf.d/99-hermes-hardening.conf
rollback_unit=hermes-firewall-rollback.service
candidate_file=$runtime_dir/nftables.candidate
before_file=$runtime_dir/nftables.before

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

stage_firewall_live() {
    require_command nft
    require_command systemd-run
    require_command systemctl
    render_firewall
    nft list ruleset >"$before_file"
    systemctl stop "$rollback_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$rollback_unit" >/dev/null 2>&1 || true
    systemd-run --unit="$rollback_unit" --on-active="${FIREWALL_ROLLBACK_SECONDS}s" --collect \
        /usr/sbin/nft -f "$before_file" >/dev/null
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
    nft -c -f "$candidate_file"
    nft list table inet hermes_guest >/dev/null 2>&1 \
        || die 'the live hermes firewall table is not loaded'
    install -m 0644 "$candidate_file" /etc/nftables.conf
    nft -c -f /etc/nftables.conf
    systemctl enable nftables >/dev/null
    systemctl restart nftables
    systemctl is-active --quiet nftables || die 'nftables service is not active after persistence'
    nft list table inet hermes_guest >/dev/null 2>&1 \
        || die 'the persisted hermes firewall table did not load'
    systemctl stop "$rollback_unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$rollback_unit" >/dev/null 2>&1 || true
    rm -f "$candidate_file" "$before_file"
    printf '%s\n' 'firewall persistence complete; rollback timer cancelled after the fresh operator session.'
}

case "$stage" in
    operator) stage_operator ;;
    privilege) stage_privilege ;;
    network) stage_network ;;
    finalize) stage_finalize ;;
    *) die "unknown stage: $stage" ;;
esac
