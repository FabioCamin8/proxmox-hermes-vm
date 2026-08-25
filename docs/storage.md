# Storage guidance

The recommended OS disk shape is a SCSI disk behind
`virtio-scsi-single`, with `discard=on`, SSD emulation where the backend
supports it, IO thread enabled, and the cache property omitted or explicitly
set to the backend-safe default.

These are recommendations, not portable truths. Directory storage, ZFS,
LVM-thin, Ceph, and other backends differ in discard, sparse allocation,
cache, and SSD semantics. Before changing a disk:

- inspect the exact volume ID and format;
- preserve the existing reference unless a migration is explicitly in scope;
- check storage status and available content types;
- do not rewrite a disk specification by guessing a volume name;
- validate the VM configuration and boot after any change.

The tested VM retained its imported root volume, used a 40 GiB SCSI disk, and
had discard, SSD emulation, and IO thread enabled. No disk move or format
conversion was performed.

The Cloud-Init drive is a small `cidata` ISO attached separately. It is
regenerated in place by `qm cloudinit update`; it is not an OS disk and should
not be treated as one.
