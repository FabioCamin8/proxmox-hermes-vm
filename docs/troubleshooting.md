# Troubleshooting

## Cloud-Init changed but did not rerun

Check the guest's cached instance identity and `cloud-init status --long`.
Changing a PVE field and running `qm cloudinit update` is not sufficient proof
that a consumed guest seed was reapplied. Stop the target, regenerate the
existing seed, and boot with a changed instance identity. Do not delete or
recreate the VM unless a safe recovery path is unavailable and that action is
explicitly approved.

## `qm cloudinit dump` differs from a custom snippet

PVE's dump API describes automatically generated content. Inspect the
`cicustom` file and, for a final proof, read the attached `cidata` volume in
read-only mode or verify from inside the guest.

## No IPv4 address

Check the VM NIC model/bridge, the exact configured MAC, the generated network
payload, the guest interface name, and DHCP traffic on the target tap. Do not
scan or select an address solely because it responds.

## Guest Agent unavailable

`agent: 1` in `qm config` enables the Proxmox integration but does not install
the guest package. Report the distinction. The runtime bootstrap installs the
Debian `qemu-guest-agent` package and starts its static service; validate both
the guest service and the Proxmox `qm agent` response.

## LightDM starts but no XFCE session

On a Debian generic-cloud VM, logind can report `CanGraphical=no` even when an
EFI framebuffer and Xorg are available. Confirm the actual `loginctl` seat and
LightDM journal. The runtime drop-in uses `start-default-seat=true` and
`logind-check-graphical=false` for this VM shape. If the session exists but
XFCE components do not start, confirm that the hermes-owned `.config` and
`.local` directories are writable and that `dbus-user-session` is installed.

## SSH command cannot reach the desktop

SSH does not inherit the LightDM session's display or D-Bus variables. Run the
command through `~/.local/bin/hermes-graphical` after the session helper has
captured the environment. Do not guess `DISPLAY=:0`; use the value observed by
`loginctl` and the XFCE process environment.

## SSH lockout risk

Keep a working session, verify `sudo -n`, validate with `sshd -t`, reload
rather than reboot solely for SSH, and test a second session before closing
the original one.

## Hardening firewall recovery

The staged firewall operation saves the prior nftables ruleset under `/run`,
loads the candidate only after `nft -c`, and schedules a short-lived systemd
rollback unit. Keep the original operator session and Proxmox console path
available. If a fresh operator SSH connection fails, wait for the rollback or
use the open recovery path; do not cancel the timer. Only the `finalize` stage
persists `/etc/nftables.conf` and cancels the timer after a fresh connection is
proven.

The network stage refuses to flush or replace an unmanaged ruleset, and it
does not merge arbitrary policies. On an already-hardened guest, use the
explicit `adopt` stage after reviewing the generated-policy match; adoption
records ownership without reapplying nftables.

If LLMNR is disabled but DNS fails, inspect `resolvectl status` and the
managed drop-in under `/etc/systemd/resolved.conf.d/`. The policy changes only
LLMNR; it does not replace DHCP DNS settings.

## MTU mismatch

Inspect the bridge, tap, virtual NIC, and guest interface. Do not force jumbo
frames from inside the guest without proving the complete network path.
