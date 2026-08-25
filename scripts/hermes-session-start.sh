#!/usr/bin/env bash

set -Eeuo pipefail

cdp_address=${HERMES_CDP_ADDRESS:-127.0.0.1}
cdp_port=${HERMES_CDP_PORT:-9222}
visible_chromium=${HERMES_VISIBLE_CHROMIUM:-true}
profile_dir=${HERMES_CHROMIUM_PROFILE_DIR:-$HOME/.local/share/hermes/chromium-profile}
env_file=${HERMES_GRAPHICAL_ENV_FILE:-$HOME/.config/hermes/graphical-session.env}

[[ "$cdp_address" == 127.0.0.1 ]] || {
    printf 'error: HERMES_CDP_ADDRESS must remain 127.0.0.1\n' >&2
    exit 1
}
[[ "$cdp_port" =~ ^[0-9]+$ && "$cdp_port" -ge 1 && "$cdp_port" -le 65535 ]] || {
    printf 'error: HERMES_CDP_PORT must be between 1 and 65535\n' >&2
    exit 1
}

[[ -n "${DISPLAY:-}" ]] || {
    printf '%s\n' 'error: graphical session did not provide DISPLAY' >&2
    exit 1
}
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || {
    printf '%s\n' 'error: graphical session did not provide DBUS_SESSION_BUS_ADDRESS' >&2
    exit 1
}

if [[ -z "${XAUTHORITY:-}" && -r "$HOME/.Xauthority" ]]; then
    export XAUTHORITY="$HOME/.Xauthority"
fi

umask 077
install -d -m 0700 "$(dirname -- "$env_file")"
{
    printf 'DISPLAY=%s\n' "$DISPLAY"
    [[ -n "${XAUTHORITY:-}" ]] && printf 'XAUTHORITY=%s\n' "$XAUTHORITY"
    printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "$DBUS_SESSION_BUS_ADDRESS"
    printf 'XDG_SESSION_TYPE=%s\n' "${XDG_SESSION_TYPE:-x11}"
    [[ -n "${XDG_CURRENT_DESKTOP:-}" ]] && printf 'XDG_CURRENT_DESKTOP=%s\n' "$XDG_CURRENT_DESKTOP"
    [[ -n "${DESKTOP_SESSION:-}" ]] && printf 'DESKTOP_SESSION=%s\n' "$DESKTOP_SESSION"
} >"$env_file"

user_environment=(DISPLAY XAUTHORITY XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION WAYLAND_DISPLAY)
systemd_bus_address=
if [[ -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/bus" ]]; then
    systemd_bus_address="unix:path=$XDG_RUNTIME_DIR/bus"
fi
if command -v systemctl >/dev/null 2>&1; then
    if [[ -n "$systemd_bus_address" ]]; then
        DBUS_SESSION_BUS_ADDRESS="$systemd_bus_address" systemctl --user import-environment "${user_environment[@]}" >/dev/null 2>&1 || true
        DBUS_SESSION_BUS_ADDRESS="$systemd_bus_address" systemctl --user set-environment "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >/dev/null 2>&1 || true
    else
        systemctl --user import-environment "${user_environment[@]}" >/dev/null 2>&1 || true
    fi
fi
if command -v dbus-update-activation-environment >/dev/null 2>&1; then
    if [[ -n "$systemd_bus_address" ]]; then
        DBUS_SESSION_BUS_ADDRESS="$systemd_bus_address" dbus-update-activation-environment --systemd "${user_environment[@]}" >/dev/null 2>&1 || true
    else
        dbus-update-activation-environment --systemd "${user_environment[@]}" >/dev/null 2>&1 || true
    fi
fi

if command -v xfconf-query >/dev/null 2>&1; then
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false >/dev/null 2>&1 || true
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 >/dev/null 2>&1 || true
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac -n -t int -s 0 >/dev/null 2>&1 || true
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-off-ac -n -t int -s 0 >/dev/null 2>&1 || true
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -n -t int -s 0 >/dev/null 2>&1 || true
fi

[[ "$visible_chromium" == true ]] || exit 0
command -v /usr/bin/chromium >/dev/null 2>&1 || {
    printf '%s\n' 'error: /usr/bin/chromium is unavailable' >&2
    exit 1
}
install -d -m 0700 "$profile_dir"

if pgrep -u "$(id -u)" -f -- "$profile_dir" >/dev/null 2>&1; then
    exit 0
fi

exec /usr/bin/chromium \
    --remote-debugging-address="$cdp_address" \
    --remote-debugging-port="$cdp_port" \
    --user-data-dir="$profile_dir" \
    --no-first-run \
    --no-default-browser-check
