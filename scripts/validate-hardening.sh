#!/usr/bin/env bash

set -Eeuo pipefail

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

env_file=
while (($# > 0)); do
    case $1 in
        --env)
            (($# >= 2)) || die '--env requires a file'
            env_file=$2
            shift 2
            ;;
        --help|-h)
            printf '%s\n' 'Usage: validate-hardening.sh [--env FILE]'
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

if [[ -n "$env_file" ]]; then
    [[ -r "$env_file" ]] || die "environment file is not readable: $env_file"
    # shellcheck disable=SC1090
    source "$env_file"
fi

HERMES_USER=${HERMES_USER:-hermes}
ADMIN_USER=${ADMIN_USER:-ops}
ENABLE_LLMNR=${ENABLE_LLMNR:-false}
ENABLE_FIREWALL=${ENABLE_FIREWALL:-false}
SSH_ALLOWED_CIDR=${SSH_ALLOWED_CIDR:-}
SSH_ALLOWED_IPV6_CIDR=${SSH_ALLOWED_IPV6_CIDR:-}
CDP_ADDRESS=${CDP_ADDRESS:-127.0.0.1}
CDP_PORT=${CDP_PORT:-9222}

[[ "$(id -u)" == 0 ]] || die 'run this validator as root, normally through sudo'
[[ "$ENABLE_LLMNR" == true || "$ENABLE_LLMNR" == false ]] || die 'ENABLE_LLMNR must be true or false'
[[ "$ENABLE_FIREWALL" == true || "$ENABLE_FIREWALL" == false ]] || die 'ENABLE_FIREWALL must be true or false'
[[ "$CDP_ADDRESS" == 127.0.0.1 ]] || die 'CDP_ADDRESS must remain 127.0.0.1'
[[ "$CDP_PORT" =~ ^[0-9]+$ && "$CDP_PORT" -ge 1 && "$CDP_PORT" -le 65535 ]] \
    || die 'CDP_PORT must be a valid port'

command -v getent >/dev/null 2>&1 || die 'getent is unavailable'
command -v runuser >/dev/null 2>&1 || die 'runuser is unavailable'
command -v visudo >/dev/null 2>&1 || die 'visudo is unavailable'
command -v ssh-keygen >/dev/null 2>&1 || die 'ssh-keygen is unavailable'

getent passwd "$HERMES_USER" >/dev/null || die "Hermes account is missing: $HERMES_USER"
getent passwd "$ADMIN_USER" >/dev/null || die "operator account is missing: $ADMIN_USER"
admin_uid=$(id -u "$ADMIN_USER")
((admin_uid >= 1000)) || die 'operator account is a system account'
admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
admin_shell=$(getent passwd "$ADMIN_USER" | cut -d: -f7)
[[ -d "$admin_home" && "$admin_shell" != /usr/sbin/nologin && "$admin_shell" != /bin/false ]] \
    || die 'operator account is not a normal local login account'

authorized_keys="$admin_home/.ssh/authorized_keys"
[[ -f "$authorized_keys" ]] || die 'operator authorized_keys is missing'
[[ "$(stat -c '%U:%a' "$authorized_keys")" == "$ADMIN_USER:600" ]] \
    || die 'operator authorized_keys ownership or mode is unsafe'
! grep -q 'PRIVATE KEY' "$authorized_keys" || die 'operator authorized_keys contains private-key material'
ssh-keygen -lf "$authorized_keys" >/dev/null 2>&1 || die 'operator authorized_keys is not a valid public key file'

operator_sudoers=/etc/sudoers.d/90-hermes-operator
operator_rule="$ADMIN_USER ALL=(ALL:ALL) NOPASSWD: ALL"
[[ -f "$operator_sudoers" ]] || die 'managed operator sudo policy is missing'
grep -Fxq "$operator_rule" "$operator_sudoers" || die 'managed operator sudo policy is incorrect'
visudo -c >/dev/null
runuser -u "$ADMIN_USER" -- sudo -n true || die 'operator non-interactive sudo proof failed'

if id -nG "$HERMES_USER" | tr ' ' '\n' | grep -qx sudo; then
    die 'Hermes remains in the sudo group'
fi
if runuser -u "$HERMES_USER" -- sudo -n true >/dev/null 2>&1; then
    die 'Hermes still has non-interactive sudo access'
fi

command -v sshd >/dev/null 2>&1 || die 'sshd is unavailable'
sshd -t
sshd_policy=$(sshd -T)
grep -Fxq 'permitrootlogin no' <<<"$sshd_policy" || die 'PermitRootLogin is not no'
grep -Fxq 'passwordauthentication no' <<<"$sshd_policy" || die 'PasswordAuthentication is not no'
grep -Fxq 'pubkeyauthentication yes' <<<"$sshd_policy" || die 'PubkeyAuthentication is not yes'

command -v resolvectl >/dev/null 2>&1 || die 'resolvectl is unavailable'
resolved_status=$(resolvectl status)
if [[ "$ENABLE_LLMNR" == false ]]; then
    ! grep -Eiq 'LLMNR setting: \+?yes|Protocols:.*\+LLMNR' <<<"$resolved_status" \
        || die 'LLMNR is still enabled in systemd-resolved'
    if ss -H -lntu | grep -Eq '([.:])5355([[:space:]]|$)'; then
        die 'LLMNR listener is still present on port 5355'
    fi
else
    printf '%s\n' 'LLMNR check: enabled by explicit configuration'
fi
getent ahosts example.com >/dev/null || die 'DNS resolution failed'
curl --fail --silent --show-error --max-time 15 https://example.com >/dev/null \
    || die 'outbound HTTPS failed'

if [[ "$ENABLE_FIREWALL" == true ]]; then
    command -v nft >/dev/null 2>&1 || die 'nft is unavailable while firewall validation is enabled'
    systemctl is-active --quiet nftables || die 'nftables service is not active'
    nft -c -f /etc/nftables.conf
    nft list table inet hermes_guest >/dev/null 2>&1 || die 'hermes nftables table is missing'
    input_chain=$(nft list chain inet hermes_guest input)
    grep -Eq 'policy drop' <<<"$input_chain" || die 'nftables input policy is not drop'
    grep -Eq 'tcp dport (22|ssh)' <<<"$input_chain" || die 'nftables SSH exception is missing'
    [[ -z "$SSH_ALLOWED_CIDR" ]] || grep -Fq "$SSH_ALLOWED_CIDR" <<<"$input_chain" \
        || die 'configured IPv4 SSH range is missing from nftables'
    [[ -z "$SSH_ALLOWED_IPV6_CIDR" ]] || grep -Fq "$SSH_ALLOWED_IPV6_CIDR" <<<"$input_chain" \
        || die 'configured IPv6 SSH range is missing from nftables'
else
    printf '%s\n' 'firewall check: disabled by explicit configuration'
fi

hermes_uid=$(id -u "$HERMES_USER")
hermes_runtime_dir=/run/user/$hermes_uid
hermes_home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
gateway_state=NOT_CONFIGURED
gateway_unit="$hermes_home/.config/systemd/user/hermes-gateway.service"
if [[ -e "$gateway_unit" ]]; then
    runuser -u "$HERMES_USER" -- env \
        HOME="$hermes_home" \
        XDG_RUNTIME_DIR="$hermes_runtime_dir" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$hermes_runtime_dir/bus" \
        systemctl --user is-active --quiet hermes-gateway.service \
        || die 'Hermes gateway is installed but not active'
    gateway_state=PASS
fi

cdp_listeners=$(ss -H -ltn "sport = :$CDP_PORT")
grep -Eq "127\.0\.0\.1:$CDP_PORT" <<<"$cdp_listeners" \
    || die 'CDP is not listening on IPv4 loopback'
! grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):$CDP_PORT([[:space:]]|$)" <<<"$cdp_listeners" \
    || die 'CDP is listening beyond loopback'
curl --fail --silent --show-error "http://$CDP_ADDRESS:$CDP_PORT/json/version" >/dev/null \
    || die 'CDP endpoint is not responding'

printf '%s\n' \
    'hardening validation passed.' \
    "operator=$ADMIN_USER" \
    "hermes=$HERMES_USER" \
    "llmnr=$([[ "$ENABLE_LLMNR" == false ]] && printf disabled || printf enabled)" \
    "firewall=$ENABLE_FIREWALL" \
    "gateway=$gateway_state"
