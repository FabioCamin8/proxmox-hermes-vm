# Verified findings

This is an engineering notebook. `VERIFIED` means observed during the base VM
or guest-runtime validation described in this repository. `RECOMMENDATION`
means a design choice that was not a destructive integration test.

## Tested versions

Status: VERIFIED

- Proxmox VE 9.2.x; observed PVE Manager 9.2.11.
- qemu-server 9.2.6 and QEMU 11.0.3.
- Debian GNU/Linux 13.6 genericcloud guest.
- Cloud-Init 25.1.4.

## Community Scripts prior art

Status: VERIFIED from the current upstream script source; not treated as the
repository implementation

Finding: the current `debian-13-vm.sh` selects the official Debian cloud image
URL based on the Cloud-Init choice. Cloud-Init mode uses the Debian 13
`genericcloud` image; the non-Cloud-Init path uses the `nocloud` image. The
script downloads the selected URL but does not verify a checksum.

Finding: storage is selected from `pvesm status -content images`. The script
uses different extensions/import formats for directory/NFS, btrfs, and other
backends. Its `THIN` flags add discard and SSD emulation for backends where
that branch applies; directory/NFS and btrfs use different handling. Advanced
disk cache selection is either the default/omitted cache or write-through.

Finding: VM creation requests OVMF, host-selected or KVM64 CPU, an optional
q35 machine, VirtIO networking, a generated MAC, `virtio-scsi-pci`, serial0,
the QEMU Guest Agent option, and SCSI boot order. In Cloud-Init mode it adds a
dedicated `scsi1` Cloud-Init drive. It optionally puts VLAN and MTU attributes
on the virtual NIC; a guest MTU still requires end-to-end network support.

Finding: the script customizes the Cloud-Init image before import, including
hostname and machine-id preparation. In Cloud-Init mode it explicitly changes
the image's `PermitRootLogin` and `PasswordAuthentication` settings to yes;
the script does not establish the final non-root hardening policy.

Finding: on errors, its cleanup trap stops and destroys the VMID it believes it
created. The repository deliberately requires an unused VMID and refuses
destructive cleanup or recreation.

Implication: the repository uses the upstream script as behavioral prior art,
not as code to copy. It requires explicit image provenance/checksum handling,
non-destructive VM identity checks, and a reviewed SSH transition.

## Cloud-Init drive

Status: VERIFIED

Finding: the VM used a dedicated `cidata` Cloud-Init drive attached as a
separate SCSI CD-ROM device. `qm cloudinit update` regenerated the existing
drive without moving or rewriting the OS disk.

Implication: inspect the seed as a separate artifact and never treat it as a
boot disk.

## First-boot recovery

Status: VERIFIED

Finding: the newly created VM had already booted once with default Cloud-Init
data. Its cached instance had completed. Updating the Cloud-Init user/network
content and regenerating the seed produced a new NoCloud instance identity.
The next boot completed Cloud-Init with an empty error list, created the
requested non-root user, and configured DHCP.

Implication: do not assume a PVE parameter change reruns consumed guest state;
prove it from the guest.

Finding: on the first hardened validation, Debian 13's `cloud-init status
--long` returned exit code 2 for recoverable deprecation notices even though it
reported `status: done` and `errors: []`. After reboot it returned exit code 0.
The guest validator accepts only these two outcomes and still requires the
completed status and empty error list.

## DNS fallback

Status: VERIFIED

Finding: PVE 9.2.x's automatic NoCloud network generator reads host resolver
and search values when the VM fields are unset. A custom network snippet with
only DHCP removed the static nameserver/search block from the actual attached
ISO.

Implication: use a reviewed `cicustom` network file when strict DHCP-only DNS
semantics are required. `qm cloudinit dump network` alone does not prove the
custom payload.

## Storage and devices

Status: VERIFIED for one PVE node

Finding: q35/OVMF, host CPU, 4 vCPUs, 8192 MiB RAM, VirtIO networking,
`virtio-scsi-single`, SCSI boot disk, discard, SSD emulation, IO thread,
serial console, and the Proxmox Agent option worked together. No disk move or
format conversion was needed.

Implication: preserve exact storage references and treat backend-specific
optimizations as recommendations.

## MTU

Status: VERIFIED for one network path

Finding: the tested bridge, tap, and Debian guest interface used MTU 9000 and
DHCP/SSH still worked.

Recommendation: the repository default remains MTU 1500. Jumbo frames are
safe only after the complete path is independently verified.

## QEMU Guest Agent

Status: VERIFIED

Finding: the Debian `qemu-guest-agent` package was installed and its static
service was started successfully. A Proxmox QEMU Guest Agent ping then
responded for the selected guest after installation and after reboot.

Implication: the Proxmox option and guest package are separate acceptance
items. `agent: 1` does not install the guest package.

## Lightweight graphical runtime

Status: VERIFIED

Finding: Debian 13 accepted the explicit X11/XFCE/LightDM package set in
`docs/desktop.md`, including `dbus-user-session`, AT-SPI, X11 diagnostics,
and Debian Chromium, without GNOME, KDE, Docker, or a standalone VNC server.

Finding: `graphical.target` is the default. LightDM's package-owned
configuration was left intact; the repository drop-in selects XFCE and, on
the validated unattended guest, autologins only the `hermes` user. The
tested generic-cloud seat required `start-default-seat=true` and
`logind-check-graphical=false` because logind reported `CanGraphical=no`.

Finding: after reboot, `loginctl` reported an active local `hermes` X11
session with desktop `xfce`, and the XFCE session, window manager, panel, and
desktop processes were running. The session's observed display was `:0`.
The session helper captured the equivalent `:0.0` value and imported it into
the `hermes` systemd user manager; both values reached the same X11 server.

Finding: AT-SPI D-Bus introspection, the AT-SPI registry, X11 input, and
screen capture all passed the current Hermes Computer Use diagnostic. The
helper disables XFCE AC blanking, DPMS, and inactivity suspend for this user
session only.

Implication: unattended Computer Use needs an active graphical session. An
SSH shell does not inherit that session's environment; use the captured
environment wrapper or launch from XFCE.

## Persistent Chromium and CDP

Status: VERIFIED

Finding: Debian Chromium `151.0.7922.169-1~deb13u1` runs as `hermes` from the
dedicated profile `/home/hermes/.local/share/hermes/chromium-profile`. XFCE
autostart recreated the visible mapped Chromium window after reboot.

Finding: the process used `--remote-debugging-address=127.0.0.1`, port
`9222`, the dedicated profile, `--no-first-run`, and
`--no-default-browser-check`. `/json/version` responded and the listening
socket had no wildcard or guest-LAN bind. The command line did not contain
`--no-sandbox`; a separate setuid helper was not present at the validator's
expected Debian path, so this notebook does not claim a deeper sandbox audit.

Finding: Hermes' local CDP detector returned the loopback endpoint without a
provider or model configuration.

Implication: the visible browser and Hermes-managed Playwright/browser tools
remain separate layers. No browser login or cloud browser provider was
configured.

## Hermes Agent runtime

Status: VERIFIED

Finding: the official HTTPS installer was downloaded to a temporary file,
inspected for its current setup/browser/Computer Use controls, and executed
as the unprivileged `hermes` user with `--skip-setup`. The observed installer
SHA-256 was
`c0380bc1f78d3d662a77663ce20cc17e14cbc4bec35e61ab7a33bac5f3afed2d`; the
validated source commit was
`1bbb6e5bce56e721ab685af4cd87df21bbff4d35`.

Finding: the managed layout is `/home/hermes/.hermes/hermes-agent`, its
virtual environment is under `venv`, and the user entry point is
`/home/hermes/.local/bin/hermes`. Observed versions were Hermes `0.20.5`,
Python `3.11.16`, Node `v26.7.0`, ripgrep `14.1.1`, ffmpeg `7.1.5`, and
`cua-driver 0.22.0`. Playwright Chromium and its cache were present. The
installer did not use `--skip-browser` or `--skip-computer-use`.

Finding: `hermes --help`, `hermes doctor`, `hermes computer-use status`, and
`hermes computer-use doctor` exited successfully after reboot. The doctor
still reported intentionally unconfigured providers, an available config
migration, a state database schema warning, optional workspace advisories,
and optional browser-system-dependency warnings. `hermes doctor --fix` was
not run.

## Reboot acceptance

Status: VERIFIED

Finding: one controlled reboot of the selected guest was performed only after
asserting that the selected Proxmox identity still matched the expected guest.
After reboot the VM was running, the Proxmox guest-agent ping responded, SSH
key access and hardening remained effective, Cloud-Init remained complete, no
failed systemd units were reported, graphical.target and LightDM were active,
the local XFCE/X11 session and mapped Chromium window returned, loopback CDP
responded, and both repository validators passed.

## SSH hardening

Status: VERIFIED

Finding: after key login and non-interactive sudo were proven, a dedicated
sshd drop-in was syntax-checked, SSH was reloaded, a second key session
succeeded, and root key login was rejected. The effective settings were
pubkey enabled, password disabled, and root login disabled.

## Least-privilege runtime hardening

Status: VERIFIED

Finding: a separate local operator account was created with public-key SSH,
locked password state, and administrative non-interactive sudo. A fresh SSH
connection proved the operator recovery path before Hermes privilege was
removed. Hermes was removed from the `sudo` group and its direct sudoers rule
was removed; `sudo -n true` then failed for Hermes while the gateway, browser,
provider request, and graphical session remained operational.

The desktop validator also runs successfully as the unprivileged Hermes
runtime user after least-privilege hardening. Hermes requires no sudo access
for desktop, CDP, or Computer Use validation.

## LLMNR hardening

Status: VERIFIED

Finding: systemd-resolved originally advertised LLMNR and listened on port
5355. A managed resolved drop-in disabled LLMNR without changing DHCP DNS
behavior. Resolver status no longer showed LLMNR, the port-5355 listeners were
gone, DNS resolution succeeded, and outbound HTTPS remained functional.

## nftables guest firewall

Status: VERIFIED

Finding: Debian nftables was installed as the explicitly requested firewall
dependency. The generated guest policy was syntax-checked, loaded behind a
short-lived rollback timer, and persisted only after a second fresh operator
SSH connection succeeded. The loaded policy permits loopback,
established/related traffic, DHCP replies, required ICMP/ICMPv6, and SSH only
from operator-supplied ranges; input and forwarding default to drop and output
remains accept. No Hermes Gateway or CDP ingress exception was added.

## Runtime after guest firewall

Status: VERIFIED

Finding: the Hermes Computer Use health report remained healthy with X11
input and screen-capture capability, and a direct screenshot succeeded after
the firewall was loaded. The direct browser semantic smoke still returned the
expected example page title and heading, and CDP remained loopback-only. A
separate pointer/key action smoke was not completed because the available
tool action did not provide a reliable no-side-effect pointer/key operation.

## Least-privilege reboot acceptance

Status: VERIFIED

Finding: after one controlled guest-only reboot, a fresh operator public-key
SSH session retained administrative sudo, a fresh Hermes session retained no
sudo access, nftables remained enabled with the expected policy, and
systemd-resolved remained LLMNR-disabled. Hermes Gateway, Hermes 0.20.5,
Chromium/CDP, the browser semantic smoke, and the wrapped Computer Use doctor
remained operational.

## Fresh VM and verified image path

Status: VERIFIED

Finding: a disposable fresh Debian 13 genericcloud VM was created through the
repository apply path. The official image was downloaded and checked against
the matching SHA512 manifest before import; the resulting boot-volume
reference and Cloud-Init drive were then verified from the final Proxmox
configuration. The current import path leaves target format selection to the
configured storage backend instead of guessing it.

## Not tested here

Status: NOT TESTED

- storage-specific apply behavior across backends;
- independent human visual confirmation through the Proxmox noVNC console;
- an authenticated browser task or a destructive Hermes task;
- destructive rollback or migration paths.
