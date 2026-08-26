# proxmox-hermes-vm

Reproducible Proxmox VE deployment guidance for a Debian generic cloud VM
prepared for Hermes Agent, secure SSH access, VirtIO devices, and an optional
visible Linux desktop/browser environment.

This repository separates a small, auditable base-VM handoff from the
Hermes/desktop/browser runtime layer. The runtime is installed by explicit
guest-side scripts and keeps provider credentials and personal workflows out
of the repository.

## Status

The complete path is validated against Proxmox VE 9.2.x (PVE Manager 9.2.11)
and a fresh Debian 13 genericcloud guest. `scripts/create-vm.sh` supports both
validated preflight and explicit `--apply` creation. The tested versions and
the small upgrade procedure are recorded in [docs/lifecycle.md](docs/lifecycle.md).
This is a single tested Proxmox/storage combination; cross-backend apply
portability is not claimed.

## Architecture

```text
Proxmox VE
└── Debian 13 generic cloud VM
    ├── Cloud-Init
    ├── OpenSSH
    ├── QEMU Guest Agent
    └── guest runtime layer
        ├── Hermes Agent
        ├── Chromium
        └── lightweight XFCE/X11 desktop
```

A VM is appropriate for a browser/computer-use deployment because it provides
kernel isolation, a complete graphical stack, a visible Proxmox console, and
a reproducible boundary for browser profiles and automation dependencies.

## Requirements

- Proxmox VE with `qm`, `pvesm`, and an available OVMF firmware package;
- an active storage pool for VM disks and a bridge for the virtual NIC;
- the official Debian 13 genericcloud image selected explicitly;
- `curl` or an equivalent downloader and checksum tooling;
- an SSH public key whose private half never leaves the operator's machine;
- root or equivalent VM configuration permission on the selected Proxmox node;
- an SSH-capable Debian guest for `scripts/validate-guest.sh`.

Run the PVE scripts on the Proxmox node. Run the guest validator inside the
Debian VM or through a controlled SSH wrapper.

## Quick start

```bash
cp config/example.env config/local.env
# Fill in VMID, STORAGE, and SSH_PUBLIC_KEY_FILE.
./scripts/validate-pve.sh config/local.env
./scripts/create-vm.sh --dry-run config/local.env
./scripts/create-vm.sh --apply config/local.env
```

`--apply` is the explicit mutation acknowledgement. It verifies the official
Debian image against its SHA512 manifest before creating a new VM, refuses an
occupied VMID, and reports the actual imported boot volume and Cloud-Init
drive. Never delete an existing VM to make a deployment succeed.

## Guest runtime

After the base VM is reachable as the non-root administrative user, run the
runtime scripts inside the guest:

```bash
sudo ./scripts/bootstrap-desktop.sh
sudo env ENABLE_AUTOLOGIN=true ./scripts/bootstrap-desktop.sh
sudo env HERMES_COMMIT=<official-hermes-commit> ./scripts/bootstrap-hermes.sh
```

The first desktop command keeps LightDM autologin disabled. Enable autologin
only when an unattended graphical session is an explicit requirement. Create
the separate operator account, prove a fresh operator SSH session, and then
remove Hermes' sudo access with [docs/hardening.md](docs/hardening.md). The
final aggregate validator is run from that fresh `ops` session:

```bash
./scripts/validate-runtime.sh --env /path/to/private-hardening.env
```

See [docs/desktop.md](docs/desktop.md), [docs/browser.md](docs/browser.md),
and [docs/hermes.md](docs/hermes.md) for the verified boundaries and known
Debian/XFCE behavior.

## Configuration

Important variables are documented in `config/example.env`:

- `VMID`, `VM_NAME`, `STORAGE`, `BRIDGE`, and optional `VLAN_ID`;
- `MTU`, which defaults to the safe public value `1500`;
- `CPU_TYPE`, `CORES`, `MEMORY_MB`, `DISK_SIZE_GB`, `MACHINE`, and `BIOS`;
- `CI_USER`, `SSH_PUBLIC_KEY_FILE`, `IPCONFIG0`, and `CIUPGRADE`;
- explicit Debian image URL/SHA512 checksum source and cache location.

Jumbo frames are opt-in. Set a larger MTU only when the complete path—from
guest through virtual NIC, bridge, physical NIC, switch, and router—supports
it. The scripts do not modify a bridge or physical interface.

## Recommended VM baseline

- machine `q35`;
- OVMF firmware;
- host CPU type, 4 vCPUs, and 6 GiB memory;
- 64 GiB SCSI boot disk;
- `virtio-scsi-single`, `discard=on`, SSD emulation when appropriate, and
  IO thread enabled;
- VirtIO NIC on the selected bridge;
- Cloud-Init drive and serial console;
- Proxmox QEMU Guest Agent option enabled, with the guest package verified
  separately.

Storage backends differ. Do not blindly reconstruct a disk reference or move
a volume between pools to match a recommendation. Preserve the exact volume
reference and validate the resulting configuration.

## Cloud-Init behavior

The base handoff creates the non-root `CI_USER`, injects only the supplied
public key, uses DHCP, disables package upgrades during first boot, and avoids
setting a login password. SSH hardening is applied only after key login and
administrative privileges have been proven.

Proxmox can regenerate the attached seed with `qm cloudinit update`. That does
not, by itself, prove that a guest will rerun consumed first-boot modules. A
changed NoCloud instance identity and a clean boot must be observed. When
strict DHCP-only DNS behavior is required, use a custom network snippet that
contains DHCP and no static nameserver/search entries; PVE 9.2.x otherwise
falls back to host resolver/search values when those VM fields are unset.

## Security model

- private keys remain on the operator machine;
- only public keys are supplied to Cloud-Init;
- no password is configured for the Cloud-Init user;
- `PubkeyAuthentication yes`, `PasswordAuthentication no`, and
  `PermitRootLogin no` are the desired post-login state;
- validate with `sshd -t` before reload and keep a working administrative
  session while testing a second session;
- local environment files, images, credentials, cookies, and key files are
  ignored and must never be committed.

For a deployed runtime, apply the staged least-privilege and guest-network
hardening in [docs/hardening.md](docs/hardening.md). The Hermes account must
not retain unrestricted sudo: terminal access combined with passwordless
`sudo` is unattended root access. The hardening scripts create a separate
operator account, require a fresh operator SSH proof before removing Hermes
privilege, optionally disable LLMNR, and apply nftables only for an explicit
operator range.

## Validation

Use `scripts/validate-pve.sh` before provisioning and
`scripts/validate-runtime.sh` after the guest has been bootstrapped and
hardened. The aggregate acceptance proof includes:

- unambiguous VM identity and a preserved pre-change configuration snapshot;
- Debian 13, expected hostname, non-root key SSH, and usable sudo;
- `cloud-init status --long` with no errors;
- DHCP address/default route and actual guest MTU;
- effective SSH settings and no failed systemd units;
- QEMU Guest Agent status, distinguishing the Proxmox option from the guest
  package/service;
- XFCE/X11, AT-SPI, Chromium, loopback-only CDP, Hermes, and Computer Use;
- `ops` administrative access and no Hermes sudo access.

## Known quirks

See `docs/findings.md` for evidence-backed details. The important ones are:

1. PVE's automatic Cloud-Init network output can include host DNS/search
   values even when the VM fields are unset.
2. `qm cloudinit dump` documents automatically generated content; it does not
   necessarily display a `cicustom` file. Inspect the attached seed when that
   distinction matters.
3. Changing the seed and instance identity can cause Cloud-Init to run a new
   instance, but this must be verified in the guest.
4. The Proxmox QEMU Guest Agent option does not install or start the guest
   package.
5. On the tested Debian cloud-init version, `cloud-init status --short` was
   unsupported; `cloud-init status --long` was the reliable check.

## Runtime boundary

Keep Hermes browser tools conceptually separate from the visible Debian
Chromium session. The runtime scripts do not modify the base Cloud-Init
document, do not install Docker or standalone VNC, and do not configure
provider credentials. The visible browser's CDP endpoint is loopback-only.

## Operator boundary

The template produces an operator-ready Hermes runtime, not a configured
Hermes account. Provider credentials, model selection, API keys, auth state,
messaging, browser logins, and personal workflows remain operator actions.
The pristine template validator reports provider and gateway state as
`NOT_CONFIGURED` when setup has intentionally not been performed.

## License

MIT. See [LICENSE](LICENSE).
