#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
desktop_script="$repo_root/scripts/validate-desktop.sh"
bootstrap_script="$repo_root/scripts/bootstrap-desktop.sh"
guest_script="$repo_root/scripts/validate-guest.sh"
runtime_script="$repo_root/scripts/validate-runtime.sh"
readme="$repo_root/README.md"
desktop_doc="$repo_root/docs/desktop.md"
security_doc="$repo_root/docs/security.md"
browser_doc="$repo_root/docs/browser.md"
proxmox_doc="$repo_root/docs/proxmox.md"

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
    'xdpyinfo' \
    'xinput list' \
    'QEMU.*USB Tablet' \
    'x11_resolution=' \
    'x11_keyboard=' \
    '--no-sandbox' \
    'curl --fail' \
    'ss -H -ltn' \
    'wmctrl -l -p' \
    'systemctl --user show-environment' \
    'REQUIRE_AUTOLOGIN' \
    'autologin-user='; do
    grep -Fq -- "$required_text" "$desktop_script"
done

for required_text in \
    'ENABLE_AUTOLOGIN=${ENABLE_AUTOLOGIN:-true}' \
    'linux-image-amd64' \
    'linux-image-cloud-amd64' \
    'apt-get purge -y linux-image-cloud-amd64' \
    'Do not autoremove' \
    'xinput'; do
    grep -Fq -- "$required_text" "$bootstrap_script"
done

grep -Fq 'REQUIRE_AUTOLOGIN=${REQUIRE_AUTOLOGIN:-true}' "$runtime_script"
grep -Fq 'ENABLE_AUTOLOGIN=true' "$desktop_doc"
grep -Fq 'ENABLE_AUTOLOGIN=false' "$desktop_doc"
! grep -Fq 'Autologin is intentionally opt-in' "$desktop_doc"
! grep -Fq 'The default remains opt-in' "$readme"

for required_text in \
    'running_kernel' \
    'linux-image-amd64 is not installed' \
    'linux-image-cloud-amd64 meta-package is still installed' \
    'modprobe --dry-run' \
    'usbhid' \
    'xhci_pci' \
    'QEMU( QEMU)? USB Tablet'; do
    grep -Fq -- "$required_text" "$guest_script"
done

for required_text in \
    'Visible browser / Computer Use workflow' \
    'hermes-graphical hermes' \
    'hermes-graphical hermes computer-use doctor' \
    'Proxmox noVNC' \
    'persistent profile' \
    'operator-owned'; do
    grep -Fq -- "$required_text" "$readme" "$browser_doc"
done

for required_text in \
    'vga: virtio' \
    'tablet: 1' \
    'does not use VirGL' \
    'linux-image-cloud-amd64'; do
    grep -Fq -- "$required_text" "$proxmox_doc"
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
