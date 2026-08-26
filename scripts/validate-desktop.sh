#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

HERMES_USER=${HERMES_USER:-hermes}
REQUIRE_AUTOLOGIN=${REQUIRE_AUTOLOGIN:-false}
CDP_ADDRESS=${CDP_ADDRESS:-127.0.0.1}
CDP_PORT=${CDP_PORT:-9222}

[[ "$(id -un)" == "$HERMES_USER" ]] || die "run this validator as $HERMES_USER"
[[ "$REQUIRE_AUTOLOGIN" == true || "$REQUIRE_AUTOLOGIN" == false ]] || die 'REQUIRE_AUTOLOGIN must be true or false'
[[ "$CDP_ADDRESS" == 127.0.0.1 ]] || die 'CDP_ADDRESS must remain 127.0.0.1'
[[ "$CDP_PORT" =~ ^[0-9]+$ && "$CDP_PORT" -ge 1 && "$CDP_PORT" -le 65535 ]] || die 'invalid CDP_PORT'

for command_name in dpkg-query loginctl pgrep tr awk curl ss wmctrl systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done

packages=(qemu-guest-agent xorg xfce4 lightdm lightdm-gtk-greeter dbus-x11 at-spi2-core x11-utils x11-xserver-utils wmctrl chromium)
for package in "${packages[@]}"; do
    status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
    [[ "$status" == 'install ok installed' ]] || die "package is not installed: $package ($status)"
done

systemctl is-active --quiet qemu-guest-agent || die 'qemu-guest-agent is not active'
systemctl is-active --quiet lightdm || die 'lightdm is not active'
[[ "$(systemctl get-default)" == graphical.target ]] || die 'graphical.target is not the default target'

failed_units=$(systemctl --failed --no-legend)
[[ -z "$failed_units" ]] || die "systemd has failed units: $failed_units"

session_id=
user_uid=$(id -u)
while read -r candidate; do
    [[ -n "$candidate" ]] || continue
    candidate_user=$(loginctl show-session "$candidate" -p Name --value)
    candidate_uid=$(loginctl show-session "$candidate" -p User --value)
    candidate_type=$(loginctl show-session "$candidate" -p Type --value)
    candidate_active=$(loginctl show-session "$candidate" -p Active --value)
    if [[ "$candidate_user" == "$HERMES_USER" && "$candidate_uid" == "$user_uid" && "$candidate_type" == x11 && "$candidate_active" == yes ]]; then
        session_id=$candidate
        break
    fi
done < <(loginctl list-sessions --no-legend | awk '{print $1}')
[[ -n "$session_id" ]] || die "no active local X11 session found for $HERMES_USER"

session_user=$(loginctl show-session "$session_id" -p Name --value)
session_type=$(loginctl show-session "$session_id" -p Type --value)
session_class=$(loginctl show-session "$session_id" -p Class --value)
session_remote=$(loginctl show-session "$session_id" -p Remote --value)
session_state=$(loginctl show-session "$session_id" -p State --value)
session_active=$(loginctl show-session "$session_id" -p Active --value)
session_display=$(loginctl show-session "$session_id" -p Display --value)
session_desktop=$(loginctl show-session "$session_id" -p Desktop --value)
[[ "$session_user" == "$HERMES_USER" ]] || die 'session user mismatch'
[[ "$session_type" == x11 ]] || die "session type is not x11: $session_type"
[[ "$session_class" == user ]] || die "session class is not user: $session_class"
[[ "$session_remote" == no ]] || die "session is remote: $session_remote"
[[ "$session_state" == active && "$session_active" == yes ]] || die 'graphical session is not active'
[[ -n "$session_display" && "$session_display" != '(null)' ]] || die 'graphical display is unknown'
[[ "$session_desktop" =~ [Xx][Ff][Cc][Ee] ]] || die "desktop is not XFCE: $session_desktop"

xfce_pid=$(pgrep -u "$user_uid" -x xfce4-session | head -n 1 || true)
[[ -n "$xfce_pid" ]] || die 'xfce4-session is not running'
pgrep -u "$user_uid" -x xfwm4 >/dev/null || die 'xfwm4 is not running'

proc_environment=$(tr '\0' '\n' </proc/"$xfce_pid"/environ)
environment_value() {
    local name=$1
    awk -F= -v name="$name" '$1 == name { sub(/^[^=]*=/, ""); print; exit }' <<<"$proc_environment"
}

display=$(environment_value DISPLAY)
xauthority=$(environment_value XAUTHORITY)
runtime_dir=$(environment_value XDG_RUNTIME_DIR)
dbus_address=$(environment_value DBUS_SESSION_BUS_ADDRESS)
process_session_type=$(environment_value XDG_SESSION_TYPE)
[[ -n "$display" ]] || die 'XFCE process did not expose DISPLAY'
[[ "$display" == "$session_display" ]] || die "DISPLAY $display differs from loginctl display $session_display"
[[ "$process_session_type" == x11 ]] || die "XFCE XDG_SESSION_TYPE is not x11: $process_session_type"
[[ -n "$runtime_dir" && -d "$runtime_dir" ]] || die 'XDG_RUNTIME_DIR is unavailable'
[[ -n "$dbus_address" ]] || die 'DBUS_SESSION_BUS_ADDRESS is unavailable'

printf '%s\n' \
    "session=$session_id" \
    "user=$session_user" \
    "type=$session_type" \
    "remote=$session_remote" \
    "desktop=$session_desktop" \
    "DISPLAY=$display" \
    "XDG_RUNTIME_DIR=$runtime_dir" \
    "DBUS_SESSION_BUS_ADDRESS=$dbus_address"

if [[ "$REQUIRE_AUTOLOGIN" == true ]]; then
    grep -qx "autologin-user=$HERMES_USER" /etc/lightdm/lightdm.conf.d/50-hermes-session.conf \
        || die 'LightDM autologin is not configured for the requested user'
fi

graphical_environment=("DISPLAY=$display" "XDG_RUNTIME_DIR=$runtime_dir" "DBUS_SESSION_BUS_ADDRESS=$dbus_address" "XDG_SESSION_TYPE=x11")
[[ -n "$xauthority" ]] && graphical_environment+=("XAUTHORITY=$xauthority")
run_graphical() {
    env "${graphical_environment[@]}" "$@"
}

canonical_display() {
    local value=$1
    [[ "$value" == *.0 ]] && value=${value%.0}
    printf '%s' "$value"
}

run_graphical dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus \
    org.freedesktop.DBus.Introspectable.Introspect >/dev/null \
    || die 'AT-SPI D-Bus service is not reachable'
pgrep -u "$user_uid" -f 'at-spi2-core|at-spi-bus-launcher|at-spi2-registryd' >/dev/null \
    || die 'AT-SPI process is not running'

home_dir=$(getent passwd "$HERMES_USER" | cut -d: -f6)
profile_dir=${HERMES_CHROMIUM_PROFILE_DIR:-$home_dir/.local/share/hermes/chromium-profile}
[[ -d "$profile_dir" ]] || die "Chromium profile is missing: $profile_dir"
[[ "$(stat -c %U "$profile_dir")" == "$HERMES_USER" ]] || die 'Chromium profile owner mismatch'

browser_pid=$(pgrep -u "$user_uid" -f 'chromium' | head -n 1 || true)
[[ -n "$browser_pid" ]] || die 'Chromium is not running as the session user'
browser_cmdline=$(tr '\0' ' ' </proc/"$browser_pid"/cmdline)
grep -Fq -- "--remote-debugging-address=$CDP_ADDRESS" <<<"$browser_cmdline" \
    || die 'Chromium CDP address flag is missing'
grep -Fq -- "--remote-debugging-port=$CDP_PORT" <<<"$browser_cmdline" \
    || die 'Chromium CDP port flag is missing'
grep -Fq -- "--user-data-dir=$profile_dir" <<<"$browser_cmdline" \
    || die 'Chromium dedicated profile flag is missing'
grep -Fq -- '--no-first-run' <<<"$browser_cmdline" || die 'Chromium no-first-run flag is missing'
grep -Fq -- '--no-default-browser-check' <<<"$browser_cmdline" \
    || die 'Chromium no-default-browser-check flag is missing'
! grep -Fq -- '--no-sandbox' <<<"$browser_cmdline" || die 'Chromium sandbox was disabled'

cdp_json=$(curl --fail --silent --show-error "http://$CDP_ADDRESS:$CDP_PORT/json/version")
grep -q 'webSocketDebuggerUrl' <<<"$cdp_json" || die 'CDP response is incomplete'
listeners=$(ss -H -ltn "sport = :$CDP_PORT")
grep -Eq "127\\.0\\.0\\.1:$CDP_PORT" <<<"$listeners" || die 'CDP is not listening on IPv4 loopback'
! grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0|\\*|\\[::\\]|::):$CDP_PORT([[:space:]]|$)" <<<"$listeners" \
    || die 'CDP is listening beyond loopback'

windows=$(run_graphical wmctrl -l -p 2>/dev/null || true)
grep -qi 'chromium' <<<"$windows" || die 'Chromium has no mapped X11 window'
printf 'chromium_window=%s\n' "$(grep -i 'chromium' <<<"$windows" | head -n 1)"

env_file="$home_dir/.config/hermes/graphical-session.env"
[[ -r "$env_file" ]] || die 'graphical session environment file is missing'
systemd_bus_address="unix:path=$runtime_dir/bus"
manager_environment=$(env DBUS_SESSION_BUS_ADDRESS="$systemd_bus_address" systemctl --user show-environment 2>/dev/null || true)
manager_display=$(awk -F= '$1 == "DISPLAY" { sub(/^[^=]*=/, ""); print; exit }' <<<"$manager_environment")
manager_dbus_address=$(awk -F= '$1 == "DBUS_SESSION_BUS_ADDRESS" { sub(/^[^=]*=/, ""); print; exit }' <<<"$manager_environment")
[[ -n "$manager_display" ]] || die 'systemd user manager did not import DISPLAY'
[[ "$(canonical_display "$manager_display")" == "$(canonical_display "$display")" ]] \
    || die "systemd user manager DISPLAY differs: $manager_display vs $display"
[[ -n "$manager_dbus_address" ]] \
    || die 'systemd user manager did not import DBUS_SESSION_BUS_ADDRESS'

sandbox_path=/usr/lib/chromium/chrome-sandbox
if [[ -e "$sandbox_path" ]]; then
    sandbox_mode=$(stat -c '%a' "$sandbox_path")
else
    sandbox_mode=unavailable
fi
printf '%s\n' \
    "chromium_pid=$browser_pid" \
    "chromium_profile=$profile_dir" \
    "chromium_sandbox_helper_mode=$sandbox_mode" \
    "systemd_user_DISPLAY=$manager_display" \
    "cdp=$CDP_ADDRESS:$CDP_PORT" \
    'desktop validation passed.'
