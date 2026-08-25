# proxmox-hermes-vm

Reproducible Proxmox VE deployment guidance for a Debian generic cloud VM
prepared for Hermes Agent, secure SSH access, VirtIO devices, and an optional
visible Linux desktop/browser environment.

This repository separates a small, auditable base-VM handoff from the
Hermes/desktop/browser runtime layer. The runtime is installed by explicit
guest-side scripts and keeps provider credentials and personal workflows out
of the repository.

## Status

The base method was validated against Proxmox VE 9.2.x (PVE Manager 9.2.11)
and a Debian 13.6 genericcloud guest. The validation used one already-created
VM and did not create a test VM. The repository's PVE validator and guest
validator are usable; `scripts/create-vm.sh` currently provides a validated
preflight and dry-run plan only. It must not be described as a from-scratch
provisioner until its apply path has been tested on an intentionally disposable
VM.

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
```

The dry run is an intentional stop point in this initial repository. Review
the plan and storage/image choices before implementing or enabling an apply
path. Never delete an existing VM to make a deployment succeed.

## Guest runtime

After the base VM is reachable as the non-root administrative user, run the
runtime scripts inside the guest:

```bash
sudo ./scripts/bootstrap-desktop.sh
sudo env ENABLE_AUTOLOGIN=true ./scripts/bootstrap-desktop.sh
sudo env HERMES_COMMIT=<official-hermes-commit> ./scripts/bootstrap-hermes.sh
```

The first desktop command keeps LightDM autologin disabled. Enable autologin
only when an unattended graphical session is an explicit requirement. The
desktop and Hermes validators are run as `hermes`:

```bash
HERMES_USER=hermes REQUIRE_AUTOLOGIN=true ./scripts/validate-desktop.sh
./scripts/validate-hermes.sh
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
- explicit Debian image URL/checksum source and cache location.

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

## Validation

Use `scripts/validate-pve.sh` before any future provisioning change and
`scripts/validate-guest.sh` after boot. The acceptance proof should include:

- unambiguous VM identity and a preserved pre-change configuration snapshot;
- Debian 13, expected hostname, non-root key SSH, and usable sudo;
- `cloud-init status --long` with no errors;
- DHCP address/default route and actual guest MTU;
- effective SSH settings and no failed systemd units;
- QEMU Guest Agent status, distinguishing the Proxmox option from the guest
  package/service.

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

## Limitations

This repository still does not implement or validate the apply path for
creating a new VM from scratch. Image URLs and checksums must be reviewed at
deployment time. Storage behavior, MTU, guest-agent packaging, and graphical
dependencies remain environment-specific. A semantic Hermes task and
provider authentication remain manual steps.

## License

MIT. See [LICENSE](LICENSE).
