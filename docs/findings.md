# Verified findings

This is an engineering notebook. `VERIFIED` means observed during the base VM
validation described in this repository. `RECOMMENDATION` means a design
choice that was not a destructive integration test.

## Tested versions

Status: VERIFIED

- Proxmox VE 9.2.x; observed PVE Manager 9.2.11.
- qemu-server 9.2.6 and QEMU 11.0.3.
- Debian GNU/Linux 13.6 genericcloud guest.
- Cloud-Init 25.1.4.

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

Finding: the Proxmox `agent: 1` option was enabled, but the Debian guest
package/service was absent and QEMU Guest Agent queries were unavailable.

Implication: the Proxmox option and guest package are separate acceptance
items. This task did not install the package.

## SSH hardening

Status: VERIFIED

Finding: after key login and non-interactive sudo were proven, a dedicated
sshd drop-in was syntax-checked, SSH was reloaded, a second key session
succeeded, and root key login was rejected. The effective settings were
pubkey enabled, password disabled, and root login disabled.

## Not tested here

Status: NOT TESTED

- creating a second VM from the repository scripts;
- image download/checksum automation;
- storage-specific apply behavior across backends;
- Hermes Agent installation;
- desktop, Chromium, Playwright, persistent browser profiles, or computer-use;
- QEMU Guest Agent package installation;
- destructive rollback or migration paths.
