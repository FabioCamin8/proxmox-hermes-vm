#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_root() {
    [[ $(id -u) -eq 0 ]] || die 'run this script as root inside the guest'
}

require_bool() {
    local name=$1
    local value=$2
    [[ "$value" == true || "$value" == false ]] || die "$name must be true or false"
}

require_root

HERMES_USER=${HERMES_USER:-hermes}
ENABLE_GUI=${ENABLE_GUI:-true}
ENABLE_AUTOLOGIN=${ENABLE_AUTOLOGIN:-true}
ENABLE_VISIBLE_CHROMIUM=${ENABLE_VISIBLE_CHROMIUM:-true}
CDP_ADDRESS=${CDP_ADDRESS:-127.0.0.1}
CDP_PORT=${CDP_PORT:-9222}

require_bool ENABLE_GUI "$ENABLE_GUI"
require_bool ENABLE_AUTOLOGIN "$ENABLE_AUTOLOGIN"
require_bool ENABLE_VISIBLE_CHROMIUM "$ENABLE_VISIBLE_CHROMIUM"
[[ "$CDP_ADDRESS" == 127.0.0.1 ]] || die 'CDP_ADDRESS must remain 127.0.0.1'
[[ "$CDP_PORT" =~ ^[0-9]+$ && "$CDP_PORT" -ge 1 && "$CDP_PORT" -le 65535 ]] \
    || die 'CDP_PORT must be between 1 and 65535'

[[ "$ENABLE_GUI" == true ]] || {
    printf '%s\n' 'ENABLE_GUI=false; no desktop changes were made.'
    exit 0
}

command -v apt-get >/dev/null 2>&1 || die 'apt-get is unavailable'
command -v systemctl >/dev/null 2>&1 || die 'systemctl is unavailable'
getent passwd "$HERMES_USER" >/dev/null || die "user does not exist: $HERMES_USER"

user_home=$(getent passwd "$HERMES_USER" | cut -d: -f6)
[[ -n "$user_home" && -d "$user_home" ]] || die "home directory is unavailable: $user_home"

package_installed() {
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == 'install ok installed' ]]
}

packages=(
    linux-image-amd64
    qemu-guest-agent
    xorg
    xfce4
    lightdm
    lightdm-gtk-greeter
    dbus-x11
    dbus-user-session
    at-spi2-core
    xfce4-power-manager
    x11-utils
    x11-xserver-utils
    xinput
    wmctrl
    chromium
)

missing=()
for package in "${packages[@]}"; do
    if ! package_installed "$package"; then
        missing+=("$package")
    fi
done

if ((${#missing[@]} > 0)); then
    env DEBIAN_FRONTEND=noninteractive apt-get update
    env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
fi

# Install the standard kernel before removing only the cloud meta-package. Do not autoremove:
# the cloud kernel may still be running until the next boot.
package_installed linux-image-amd64 \
    || die 'linux-image-amd64 is not installed; refusing to continue'
if package_installed linux-image-cloud-amd64; then
    env DEBIAN_FRONTEND=noninteractive apt-get purge -y linux-image-cloud-amd64
fi
! package_installed linux-image-cloud-amd64 \
    || die 'linux-image-cloud-amd64 is still installed after kernel transition'

lightdm_dropin=/etc/lightdm/lightdm.conf.d/50-hermes-session.conf
install -d -m 0755 /etc/lightdm/lightdm.conf.d
lightdm_tmp=$(mktemp)
trap 'rm -f -- "$lightdm_tmp"' EXIT
{
    printf '%s\n' '[LightDM]'
    printf '%s\n' 'start-default-seat=true'
    printf '%s\n' 'logind-check-graphical=false'
    printf '\n'
    printf '%s\n' '[Seat:*]'
    printf '%s\n' 'allow-guest=false'
    printf '%s\n' 'greeter-session=lightdm-gtk-greeter'
    printf '%s\n' 'user-session=xfce'
    if [[ "$ENABLE_AUTOLOGIN" == true ]]; then
        printf 'autologin-user=%s\n' "$HERMES_USER"
        printf '%s\n' 'autologin-user-timeout=0'
        printf '%s\n' 'autologin-session=xfce'
    fi
} >"$lightdm_tmp"
install -m 0644 "$lightdm_tmp" "$lightdm_dropin"
rm -f -- "$lightdm_tmp"
trap - EXIT

user_bin="$user_home/.local/bin"
user_local="$user_home/.local"
user_data="$user_local/share"
user_config="$user_home/.config"
user_autostart="$user_config/autostart"
profile_dir="$user_home/.local/share/hermes/chromium-profile"
install -d -m 0755 "$user_local" "$user_data" "$user_bin" "$user_config" "$user_autostart"
install -d -m 0700 "$user_home/.config/hermes" "$profile_dir"
chown "$HERMES_USER:$HERMES_USER" "$user_local" "$user_data" "$user_bin" "$user_config" "$user_autostart" "$user_home/.config/hermes"
install -m 0755 "$script_dir/hermes-session-start.sh" "$user_bin/hermes-session-start"
install -m 0755 "$script_dir/hermes-with-graphical-env.sh" "$user_bin/hermes-graphical"

chromium_desktop="$user_autostart/hermes-visible-chromium.desktop"
if [[ "$ENABLE_VISIBLE_CHROMIUM" == true ]]; then
    chromium_tmp=$(mktemp)
    trap 'rm -f -- "$chromium_tmp"' EXIT
    {
        printf '%s\n' '[Desktop Entry]'
        printf '%s\n' 'Type=Application'
        printf '%s\n' 'Name=Hermes visible Chromium'
        printf 'Exec=%s\n' "$user_bin/hermes-session-start"
        printf '%s\n' 'OnlyShowIn=XFCE;'
        printf '%s\n' 'X-GNOME-Autostart-enabled=true'
        printf '%s\n' 'NoDisplay=false'
    } >"$chromium_tmp"
    install -m 0644 "$chromium_tmp" "$chromium_desktop"
    rm -f -- "$chromium_tmp"
    trap - EXIT
else
    rm -f -- "$chromium_desktop"
fi

chown "$HERMES_USER:$HERMES_USER" \
    "$user_bin/hermes-session-start" \
    "$user_bin/hermes-graphical" \
    "$user_config/hermes"
chown -R "$HERMES_USER:$HERMES_USER" "$profile_dir"

systemctl start qemu-guest-agent
systemctl set-default graphical.target >/dev/null
systemctl enable lightdm >/dev/null
systemctl start graphical.target
if systemctl is-active --quiet lightdm; then
    systemctl restart lightdm
else
    systemctl start lightdm
fi

printf '%s\n' \
    'Desktop bootstrap completed.' \
    "HERMES_USER=$HERMES_USER" \
    "ENABLE_AUTOLOGIN=$ENABLE_AUTOLOGIN" \
    "ENABLE_VISIBLE_CHROMIUM=$ENABLE_VISIBLE_CHROMIUM" \
    "CDP_ADDRESS=$CDP_ADDRESS" \
    "CDP_PORT=$CDP_PORT" \
    "CHROMIUM_PROFILE=$profile_dir"
