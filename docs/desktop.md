# Debian graphical desktop

The desktop layer is a separate guest-runtime step. It uses X11, XFCE, and
LightDM so a persistent session can be inspected through the Proxmox graphical
console and reached by Hermes Computer Use.

## Public-safe defaults

`scripts/bootstrap-desktop.sh` defaults to:

```text
HERMES_USER=hermes
ENABLE_GUI=true
ENABLE_AUTOLOGIN=false
ENABLE_VISIBLE_CHROMIUM=true
CDP_ADDRESS=127.0.0.1
CDP_PORT=9222
```

Autologin is intentionally opt-in. An unattended Computer Use deployment can
enable it explicitly after reviewing the local security boundary:

```bash
sudo env \
  HERMES_USER=hermes \
  ENABLE_AUTOLOGIN=true \
  ENABLE_VISIBLE_CHROMIUM=true \
  CDP_ADDRESS=127.0.0.1 \
  CDP_PORT=9222 \
  ./scripts/bootstrap-desktop.sh
```

The script must run inside the Debian guest as root. It does not modify a
Proxmox host, bridge, storage pool, or other guest.

## Debian package set

The tested explicit package set is:

- `qemu-guest-agent`
- `xorg`
- `xfce4`
- `lightdm` and `lightdm-gtk-greeter`
- `dbus-x11` and `dbus-user-session`
- `at-spi2-core`
- `xfce4-power-manager`
- `x11-utils`, `x11-xserver-utils`, and `wmctrl`
- `chromium`

The bootstrap uses `--no-install-recommends` and does not install
`xfce4-goodies`, GNOME, KDE, Docker, or a standalone VNC server.

The QEMU Guest Agent unit is `static` on Debian 13. The script starts it; it
does not claim that a static unit can be enabled. Proxmox `agent: 1` and the
guest package/service are separate checks.

## LightDM and X11 session

The script writes `/etc/lightdm/lightdm.conf.d/50-hermes-session.conf` and
leaves the package-owned LightDM configuration unchanged. The drop-in selects
the XFCE session and disables guest login. When autologin is enabled it adds
only the hermes autologin settings.

The tested Debian generic-cloud VM reported `CanGraphical=no` for its logind
seat even though it had an EFI framebuffer. The drop-in therefore also sets
`start-default-seat=true` and `logind-check-graphical=false`. Xorg then starts
on the local virtual display; this is a VM-specific LightDM compatibility
setting, not a request to expose X11 remotely.

The session helper creates a narrow, hermes-owned environment file at:

```text
~/.config/hermes/graphical-session.env
```

It records the values observed inside the real XFCE session, imports the
display variables into the hermes systemd user manager through
`/run/user/<uid>/bus`, and leaves the actual XFCE D-Bus address intact for
desktop applications. It also disables XFCE AC display blanking, DPMS, and
inactivity suspend for this user session only.

An SSH-launched command does not inherit the XFCE environment. After one
graphical login, use the generated wrapper when a command must reach the
desktop from SSH:

```bash
~/.local/bin/hermes-graphical hermes computer-use doctor
```

The wrapper also prepends `~/.local/bin` so this works from a non-login SSH
command where the managed Hermes entry point is not otherwise on `PATH`.
The X11 display may be reported as `:0` by `loginctl` and `xfce4-session` and
as the equivalent `:0.0` by X11 clients; validation treats only that default
screen suffix as equivalent and still checks reachability.

## Validation

Run the validator as the desktop user:

```bash
HERMES_USER=hermes REQUIRE_AUTOLOGIN=true ./scripts/validate-desktop.sh
```

It checks package state, QEMU Guest Agent, graphical target, LightDM, the
actual `loginctl` session, X11 `DISPLAY`, XFCE processes, AT-SPI D-Bus, the
mapped Chromium window, CDP loopback binding, and systemd-user environment
import. It does not treat an Xorg process alone as proof of a rendered GUI.

Human-visible confirmation through the Proxmox console remains a useful
operator acceptance step; the automated proof includes a mapped X11 window and
the Computer Use driver's working X11 screen-capture path.
