#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
harden_script="$repo_root/scripts/harden-guest.sh"
validate_script="$repo_root/scripts/validate-hardening.sh"
example_env="$repo_root/config/hardening.example.env"
firewall_policy="$repo_root/scripts/lib/firewall-policy.sh"

[[ -x "$harden_script" ]] || { printf '%s\n' 'hardening script is not executable' >&2; exit 1; }
[[ -x "$validate_script" ]] || { printf '%s\n' 'hardening validator is not executable' >&2; exit 1; }
[[ -r "$firewall_policy" ]] || { printf '%s\n' 'shared firewall policy is missing' >&2; exit 1; }
grep -Fq 'render_firewall_policy' "$firewall_policy"
grep -Fq 'canonicalize_firewall_file' "$firewall_policy"

grep -Fxq 'ENABLE_FIREWALL=false' "$example_env"
grep -Fxq 'ENABLE_LLMNR=false' "$example_env"
grep -Fq 'ADMIN_SSH_PUBLIC_KEY_FILE' "$harden_script"
grep -Fq 'sudo -n true' "$harden_script"
grep -Fq 'sudo -n -l -U "$HERMES_USER"' "$harden_script"
grep -Fq 'nft -c -f' "$harden_script"
grep -Fq 'systemd-run --unit="$rollback_unit"' "$harden_script"
grep -Fq 'LLMNR=no' "$harden_script"
grep -Fq 'permitrootlogin no' "$validate_script"
grep -Fq 'hermes-gateway.service' "$validate_script"
grep -Fq 'sudo -n -l -U "$HERMES_USER"' "$validate_script"
grep -Fq 'repository-managed nftables ownership marker' "$validate_script"
grep -Fq 'compare_canonical_firewall_files' "$validate_script"
grep -Fq 'nft list ruleset' "$validate_script"
! grep -Fq 'RUN_RUNTIME_SMOKE' "$validate_script"

grep -Fq 'SSH_ALLOWED_CIDR or SSH_ALLOWED_IPV6_CIDR' "$firewall_policy"
grep -Fq 'stage_adopt' "$harden_script"
grep -Fq 'unmanaged or ambiguous nftables rules are loaded' "$harden_script"
grep -Fq 'live_firewall_matches_candidate' "$harden_script"
guard_line=$(grep -n 'inspect_firewall_state' "$harden_script" | head -n1 | cut -d: -f1)
apply_line=$(grep -n 'nft -f "\$candidate_file"' "$harden_script" | head -n1 | cut -d: -f1)
((guard_line < apply_line))

fixture_root=$(mktemp -d)
trap 'rm -rf "$fixture_root"' EXIT
mock_bin="$fixture_root/bin"
mkdir -p "$mock_bin"

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'printf "nft %s\\n" "$*" >>"${NFT_ACTION_LOG:?}"' \
    'case "${1:-}" in' \
    '    -c) exit 0 ;;' \
    '    list)' \
    '        [[ "${2:-}" == ruleset ]] || exit 1' \
    '        cat "$NFT_RULESET_FIXTURE"' \
    '        ;;' \
    '    -f) exit 0 ;;' \
    '    *) exit 1 ;;' \
    'esac' >"$mock_bin/nft"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "systemd-run %s\\n" "$*" >>"${NFT_ACTION_LOG:?}"' >"$mock_bin/systemd-run"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "systemctl %s\\n" "$*" >>"${NFT_ACTION_LOG:?}"' >"$mock_bin/systemctl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' >"$mock_bin/resolvectl"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'exit 0' >"$mock_bin/runuser"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    '[[ "${1:-}" == passwd && "${2:-}" == ops ]] || exit 1' \
    'printf "%s\\n" "ops:x:1000:1000::/home/ops:/bin/bash"' >"$mock_bin/getent"
chmod 0755 "$mock_bin/nft" "$mock_bin/systemd-run" "$mock_bin/systemctl" \
    "$mock_bin/resolvectl" "$mock_bin/runuser" "$mock_bin/getent"

run_network_fixture() {
    local case_dir=$1
    local output_file=$2
    PATH="$mock_bin:$PATH" \
        SUDO_USER=ops \
        ADMIN_USER=ops \
        ENABLE_LLMNR=true \
        ENABLE_FIREWALL=true \
        SSH_ALLOWED_CIDR=192.0.2.0/24 \
        HERMES_HARDENING_STATE_DIR="$case_dir/state" \
        HERMES_HARDENING_RUNTIME_DIR="$case_dir/runtime" \
        HERMES_RESOLVED_DROPIN="$case_dir/resolved.conf" \
        HERMES_NFTABLES_CONFIG="$case_dir/nftables.conf" \
        NFT_RULESET_FIXTURE="$case_dir/ruleset" \
        NFT_ACTION_LOG="$case_dir/actions" \
        "$harden_script" --stage network >"$output_file" 2>&1
}

unmanaged_case="$fixture_root/unmanaged"
mkdir -p "$unmanaged_case"
printf '%s\n' 'table inet foreign { chain input { type filter hook input priority 0; policy accept; } }' \
    >"$unmanaged_case/ruleset"
: >"$unmanaged_case/actions"
if run_network_fixture "$unmanaged_case" "$unmanaged_case/output"; then
    printf '%s\n' 'unmanaged nftables fixture was not refused' >&2
    exit 1
fi
! grep -Fq 'nft -f ' "$unmanaged_case/actions"
! grep -Fq 'systemd-run ' "$unmanaged_case/actions"

unmanaged_config_case="$fixture_root/unmanaged-config"
mkdir -p "$unmanaged_config_case"
: >"$unmanaged_config_case/ruleset"
printf '%s\n' 'table inet foreign { }' >"$unmanaged_config_case/nftables.conf"
config_digest=$(sha256sum "$unmanaged_config_case/nftables.conf")
: >"$unmanaged_config_case/actions"
if run_network_fixture "$unmanaged_config_case" "$unmanaged_config_case/output"; then
    printf '%s\n' 'unmanaged nftables configuration was not refused' >&2
    exit 1
fi
[[ "$config_digest" == "$(sha256sum "$unmanaged_config_case/nftables.conf")" ]]
! grep -Fq 'nft -f ' "$unmanaged_config_case/actions"
! grep -Fq 'systemd-run ' "$unmanaged_config_case/actions"

default_config_case="$fixture_root/default-config"
mkdir -p "$default_config_case"
: >"$default_config_case/ruleset"
cat >"$default_config_case/nftables.conf" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority filter;
    }
    chain forward {
        type filter hook forward priority filter;
    }
    chain output {
        type filter hook output priority filter;
    }
}
EOF
: >"$default_config_case/actions"
run_network_fixture "$default_config_case" "$default_config_case/output"
grep -Fq 'nft -f ' "$default_config_case/actions"
grep -Fq 'firewall live policy applied' "$default_config_case/output"

finalize_case="$fixture_root/finalize"
mkdir -p "$finalize_case"
: >"$finalize_case/ruleset"
: >"$finalize_case/actions"
run_network_fixture "$finalize_case" "$finalize_case/network-output"
cp "$finalize_case/runtime/nftables.candidate" "$finalize_case/expected.conf"
sed '/^[[:space:]]*flush ruleset[[:space:]]*$/d' \
    "$finalize_case/runtime/nftables.candidate" >"$finalize_case/ruleset"
PATH="$mock_bin:$PATH" \
    SUDO_USER=ops \
    ADMIN_USER=ops \
    ENABLE_LLMNR=true \
    ENABLE_FIREWALL=true \
    SSH_ALLOWED_CIDR=192.0.2.0/24 \
    HERMES_HARDENING_STATE_DIR="$finalize_case/state" \
    HERMES_HARDENING_RUNTIME_DIR="$finalize_case/runtime" \
    HERMES_RESOLVED_DROPIN="$finalize_case/resolved.conf" \
    HERMES_NFTABLES_CONFIG="$finalize_case/nftables.conf" \
    NFT_RULESET_FIXTURE="$finalize_case/ruleset" \
    NFT_ACTION_LOG="$finalize_case/actions" \
    "$harden_script" --stage finalize >"$finalize_case/finalize-output" 2>&1
cmp -s "$finalize_case/expected.conf" "$finalize_case/nftables.conf"
[[ "$(stat -c '%u:%g:%a' "$finalize_case/state/nftables-managed")" == 0:0:600 ]]

managed_case="$fixture_root/managed"
mkdir -p "$managed_case"
: >"$managed_case/ruleset"
: >"$managed_case/actions"
run_network_fixture "$managed_case" "$managed_case/clean-output"
grep -Fq 'nft -f ' "$managed_case/actions"
cp "$managed_case/runtime/nftables.candidate" "$managed_case/nftables.conf"
sed -e '/^[[:space:]]*flush ruleset[[:space:]]*$/d' \
    -e 's/icmp type { destination-unreachable, echo-request, echo-reply, time-exceeded, parameter-problem }/icmp type { echo-reply, destination-unreachable, echo-request, time-exceeded, parameter-problem }/' \
    "$managed_case/runtime/nftables.candidate" >"$managed_case/ruleset"
: >"$managed_case/actions"
PATH="$mock_bin:$PATH" \
    SUDO_USER=ops \
    ADMIN_USER=ops \
    ENABLE_LLMNR=true \
    ENABLE_FIREWALL=true \
    SSH_ALLOWED_CIDR=192.0.2.0/24 \
    HERMES_HARDENING_STATE_DIR="$managed_case/state" \
    HERMES_HARDENING_RUNTIME_DIR="$managed_case/runtime" \
    HERMES_RESOLVED_DROPIN="$managed_case/resolved.conf" \
    HERMES_NFTABLES_CONFIG="$managed_case/nftables.conf" \
    NFT_RULESET_FIXTURE="$managed_case/ruleset" \
    NFT_ACTION_LOG="$managed_case/actions" \
    "$harden_script" --stage adopt >"$managed_case/adopt-output" 2>&1
[[ -f "$managed_case/state/nftables-managed" ]]
! grep -Fq 'nft -f ' "$managed_case/actions"
: >"$managed_case/actions"
run_network_fixture "$managed_case" "$managed_case/managed-output"
grep -Fq 'already matches the repository-managed policy' "$managed_case/managed-output"
! grep -Fq 'nft -f ' "$managed_case/actions"
cp "$managed_case/nftables.conf" "$managed_case/expected.conf"
printf '%s\n' '# drift' >>"$managed_case/nftables.conf"
: >"$managed_case/actions"
if run_network_fixture "$managed_case" "$managed_case/drift-output"; then
    printf '%s\n' 'managed marker was trusted without config validation' >&2
    exit 1
fi
! grep -Fq 'nft -f ' "$managed_case/actions"
cp "$managed_case/expected.conf" "$managed_case/nftables.conf"

printf '%s\n' 'hardening contract passed.'
