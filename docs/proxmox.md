# Proxmox deployment model

## Tested baseline

The base VM path was validated on Proxmox VE 9.2.x, specifically PVE Manager
9.2.11 with qemu-server 9.2.6 and QEMU 11.0.3. This records the tested point,
not an assertion that other patch releases are unsupported.

The validated VM used q35, OVMF, host CPU type, 4 vCPUs, 8192 MiB RAM, a
VirtIO NIC, a SCSI boot disk, a dedicated Cloud-Init drive, a serial console,
and the Proxmox QEMU Guest Agent option. The boot disk retained its original
storage volume reference and used `virtio-scsi-single`, `discard=on`,
`ssd=on`, and `iothread=on`; no cache property was added.

## Safe workflow

1. Inspect `qm list`, `pct list`, `pvesm status`, and the selected bridge.
2. Establish VM identity using multiple independent attributes.
3. Save `qm config`, status, and generated Cloud-Init evidence outside the
   cluster configuration directory.
4. Validate the installed `qm` syntax before using it.
5. Change only the verified VM and inspect the generated seed before boot.
6. Correlate a guest address to the VM NIC MAC or QEMU Guest Agent; do not use
   ping alone as identity proof.
7. Validate SSH key access before SSH hardening.

The scripts refuse an occupied VMID and never delete or recreate a VM.

## Creation

Run the dry run first, review its output, then explicitly acknowledge
Proxmox mutations with `--apply`:

```bash
scripts/create-vm.sh --dry-run config/local.env
scripts/create-vm.sh --apply config/local.env
```

The apply path downloads the configured official Debian genericcloud image to
the configured cache, verifies it against the matching `SHA512SUMS` entry,
creates the VM, imports the verified image with `qm importdisk` using the
storage backend's native default format, and obtains
the real volume reference from the import result/`qm config`. It then attaches
that reference as `scsi0`, resizes only after the attachment is confirmed,
adds the Cloud-Init drive, and regenerates the seed. A failed post-create step
leaves the newly created VM for explicit operator review; the script never
performs broad or implicit deletion.

## Representative configuration

```text
machine: q35
bios: ovmf
cpu: host
cores: 4
memory: 6144 or 8192
scsihw: virtio-scsi-single
scsi0: <STORAGE_VOLUME>,discard=on,ssd=1,iothread=1
scsi1: <CLOUD_INIT_VOLUME>,media=cdrom
net0: virtio=<GENERATED_MAC>,bridge=<BRIDGE>
serial0: socket
agent: 1
boot: order=scsi0
```

The placeholder values must come from current Proxmox inspection. Storage
backends differ, so scripts must not guess a volume name, format, or cache
policy. The import path deliberately omits `--format`; Proxmox selects the
backend-appropriate target format.

## Cloud-Init commands

The relevant PVE 9.2.x commands are:

```bash
qm set <VMID> --ciuser hermes
qm set <VMID> --sshkeys <SSH_PUBLIC_KEY_FILE>
qm set <VMID> --ipconfig0 ip=dhcp
qm set <VMID> --ciupgrade 0
qm cloudinit update <VMID>
qm cloudinit dump <VMID> user
qm cloudinit dump <VMID> network
qm cloudinit dump <VMID> meta
```

`qm cloudinit dump` is the automatically generated view. If `cicustom` is in
use, inspect the referenced snippet and, where necessary, the attached
`cidata` volume as well.

## Community Scripts prior art

The upstream Community Scripts Debian 13 installer is useful for understanding
the image and PVE wiring, but it is not copied into this repository. The
current source selects the official Debian 13 `genericcloud` image when
Cloud-Init is enabled and the `nocloud` image otherwise. It downloads without
checksum verification, customizes the image with `virt-customize`, creates the
VM with OVMF/optional q35, VirtIO networking, `virtio-scsi-pci`, serial0, the
Agent option, and attaches Cloud-Init as `scsi1` in Cloud-Init mode.

Its storage branch varies disk format, extension, and discard/SSD flags by
backend. Its Cloud-Init image customization enables root and password SSH
settings, so a secure deployment must verify the non-root key path and apply
an explicit hardening drop-in afterward. Its error cleanup can destroy the
selected VMID. These behaviors are documented findings, not defaults that
this repository silently inherits.
