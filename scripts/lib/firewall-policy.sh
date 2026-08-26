#!/usr/bin/env bash

# Callers provide die(), SSH_ALLOWED_CIDR, and SSH_ALLOWED_IPV6_CIDR.

validate_firewall_ipv4_cidr() {
    local value=$1
    [[ "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
        || die "invalid IPv4 SSH_ALLOWED_CIDR: $value"
}

validate_firewall_ipv6_cidr() {
    local value=$1
    [[ "$value" =~ ^[0-9A-Fa-f:]+/[0-9]{1,3}$ ]] \
        || die "invalid IPv6 SSH_ALLOWED_IPV6_CIDR: $value"
}

append_firewall_ssh_rule() {
    local value=$1
    if [[ "$value" == *:* ]]; then
        validate_firewall_ipv6_cidr "$value"
        printf '        ip6 saddr %s tcp dport 22 ct state new accept\n' "$value"
    else
        validate_firewall_ipv4_cidr "$value"
        printf '        ip saddr %s tcp dport 22 ct state new accept\n' "$value"
    fi
}

render_firewall_policy() {
    local output=$1
    [[ -n "${SSH_ALLOWED_CIDR:-}" || -n "${SSH_ALLOWED_IPV6_CIDR:-}" ]] \
        || die 'firewall requires SSH_ALLOWED_CIDR or SSH_ALLOWED_IPV6_CIDR'
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
        [[ -z "${SSH_ALLOWED_CIDR:-}" ]] || append_firewall_ssh_rule "$SSH_ALLOWED_CIDR"
        [[ -z "${SSH_ALLOWED_IPV6_CIDR:-}" ]] || append_firewall_ssh_rule "$SSH_ALLOWED_IPV6_CIDR"
        printf '%s\n' '    }' '    chain forward {'
        printf '%s\n' '        type filter hook forward priority 0; policy drop;'
        printf '%s\n' '    }' '    chain output {'
        printf '%s\n' '        type filter hook output priority 0; policy accept;'
        printf '%s\n' '    }' '}'
    } >"$output"
}

canonicalize_firewall_file() {
    local file=$1
    awk '
        function normalize_sets(line, open, close_pos, expression, body, count, i, j, item, normalized, values) {
            if (match(line, /\{[^{}]*\}/)) {
                open = RSTART
                close_pos = RSTART + RLENGTH - 1
                expression = substr(line, open, RLENGTH)
                body = substr(expression, 2, length(expression) - 2)
                count = split(body, values, /,[[:space:]]*/)
                for (i = 1; i <= count; i++) {
                    sub(/^[[:space:]]*/, "", values[i])
                    sub(/[[:space:]]*$/, "", values[i])
                }
                for (i = 1; i <= count; i++) {
                    for (j = i + 1; j <= count; j++) {
                        if (values[j] < values[i]) {
                            item = values[i]
                            values[i] = values[j]
                            values[j] = item
                        }
                    }
                }
                normalized = "{ " values[1]
                for (i = 2; i <= count; i++) {
                    normalized = normalized ", " values[i]
                }
                normalized = normalized " }"
                line = substr(line, 1, open - 1) normalized substr(line, close_pos + 1)
            }
            return line
        }
        /^[[:space:]]*flush ruleset[[:space:]]*$/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            sub(/[[:space:]]*$/, "", line)
            gsub(/[[:space:]]+/, " ", line)
            gsub(/priority filter/, "priority 0", line)
            print normalize_sets(line)
        }
    ' "$file"
}
