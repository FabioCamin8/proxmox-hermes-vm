#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
desktop_script="$repo_root/scripts/validate-desktop.sh"
readme="$repo_root/README.md"
security_doc="$repo_root/docs/security.md"

[[ -x "$desktop_script" ]] || { printf '%s\n' 'desktop validator is not executable' >&2; exit 1; }

! grep -Fq 'sudo -n true' "$desktop_script"
! grep -Fq 'sudo' "$desktop_script"

for required_text in \
    'dpkg-query' \
    'qemu-guest-agent' \
    'systemctl is-active --quiet qemu-guest-agent' \
    'systemctl is-active --quiet lightdm' \
    'systemctl get-default' \
    'systemctl --failed --no-legend' \
    'loginctl list-sessions --no-legend' \
    'loginctl show-session' \
    'session_remote' \
    'session_desktop' \
    'DISPLAY' \
    'DBUS_SESSION_BUS_ADDRESS' \
    'org.a11y.Bus' \
    'at-spi' \
    'chromium' \
    '--no-sandbox' \
    'curl --fail' \
    'ss -H -ltn' \
    'wmctrl -l -p' \
    'systemctl --user show-environment' \
    'REQUIRE_AUTOLOGIN' \
    'autologin-user='; do
    grep -Fq -- "$required_text" "$desktop_script"
done

grep -Fq 'operator Unix account -> sudo -> root' "$security_doc"
grep -Fq 'Hermes Agent -> unprivileged hermes -X-> sudo/root' "$security_doc"
grep -Fq 'The Hermes account must' "$readme"
grep -Fq 'not retain unrestricted sudo' "$readme"

for forbidden_pattern in \
    'grant.{0,80}sudo.{0,80}hermes' \
    'give.{0,80}sudo.{0,80}hermes' \
    'add.{0,80}hermes.{0,80}sudo' \
    'restore.{0,80}hermes.{0,80}sudo' \
    'hermes.{0,80}sudo.{0,80}(allow|grant|enable|membership)' \
    'usermod.{0,80}hermes.{0,80}sudo'; do
    ! grep -Eiq "$forbidden_pattern" "$readme" "$repo_root"/docs/*.md
done

printf '%s\n' 'desktop validator contract passed.'
