# Lifecycle baseline

Status: VERIFIED on 2026-08-26

This document records the reproducible baseline for the complete template
path. It contains no deployment-specific addresses, VM identifiers, network
ranges, keys, credentials, or browser state.

The complete path and verified image download were exercised once on the
tested Proxmox/storage combination. Cross-backend storage behavior remains an
explicitly untested boundary; this baseline does not claim portability across
storage plugins.

## Verified baseline

- Proxmox VE 9.2.x; observed PVE Manager 9.2.11, qemu-server 9.2.6, and QEMU
  11.0.3.
- Debian GNU/Linux 13 genericcloud amd64 guest.
- Cloud-Init 25.1.4.
- q35 machine, OVMF firmware, host CPU, VirtIO networking, and
  virtio-scsi-single storage.
- Cloud-Init user data used DHCP and public-key SSH. The image was downloaded
  from the official Debian source and verified against its SHA512 manifest
  before import.
- Hermes Agent 0.20.5 from the pinned official source commit
  `1bbb6e5bce56e721ab685af4cd87df21bbff4d35`.
- Python 3.11.16, Node.js 24.20.0, npm 11.19.0, ripgrep 14.1.1, ffmpeg
  7.1.5, and cua-driver 0.22.1.
- Debian Chromium 151.0.7922.169 and Playwright browser dependencies.

The runtime was validated after a controlled guest reboot. The aggregate
validator passed the base guest, operator/Hermes privilege boundary, SSH
policy, desktop/X11/AT-SPI, Chromium loopback CDP, Hermes, and Computer Use
checks. Provider and gateway state were intentionally `NOT_CONFIGURED`; no
provider credential or browser login was added.

## Upgrade procedure

1. Review the current Git state and run the read-only PVE validator.
2. Run `create-vm.sh --dry-run` and review the selected image, checksum source,
   storage, bridge, and Cloud-Init inputs.
3. Run `create-vm.sh --apply` only with an unused VMID and an explicit operator
   acknowledgement of the Proxmox mutation.
4. Preserve the generated image checksum, exact imported volume reference, and
   Cloud-Init drive evidence.
5. Apply guest runtime changes in order: desktop, Hermes, operator account,
   fresh operator SSH proof, Hermes privilege removal, network policy, fresh
   SSH proof, and firewall finalization.
6. Run `validate-runtime.sh` from the fresh operator session, then perform one
   controlled guest reboot and run the validator again.

For a later Hermes upgrade, select and review a new official commit, rerun the
bootstrap wrapper, and repeat the provider-free Hermes and aggregate runtime
checks. Do not run configuration migrations, provider authentication, browser
login, or destructive snapshot rollback as an unattended upgrade step.

## Safety boundaries

- The apply path refuses an occupied VMID and never deletes a VM to recover
  from an error.
- Firewall enablement is opt-in and requires an explicit management range. It
  refuses unmanaged nftables state and uses a temporary rollback timer before
  persistence.
- The template keeps provider credentials, auth state, personal workflows,
  SSH private keys, and browser profiles outside Git.
- Snapshot rollback and provider-dependent smoke behavior remain external
  operator actions unless separately authorized and tested.
