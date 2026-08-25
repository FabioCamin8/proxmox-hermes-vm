# Cloud-Init contract

The base contract is intentionally small:

- create `CI_USER`;
- inject one or more explicitly supplied public SSH keys;
- set `VM_NAME` as hostname/FQDN;
- configure DHCP for IPv4;
- leave IPv6 at the image/network default;
- disable automatic package upgrades during first boot;
- configure no login password.

The `cloud-init/` files are templates. The Proxmox CLI can generate equivalent
user data from VM configuration, which avoids storing a rendered key in the
repository.

## First boot

Cloud-Init caches state by datasource instance identity. Updating the PVE seed
while a guest is already booted does not prove that consumed modules will run
again. When a new seed is necessary:

1. stop only the verified VM;
2. update the PVE fields and regenerate the existing Cloud-Init drive;
3. verify the seed contents and instance identity;
4. boot the VM and inspect `cloud-init status --long`, logs, and the guest
   identity.

The tested Debian genericcloud guest completed all stages with an empty error
list after consuming a regenerated NoCloud seed.

## DNS and network snippets

PVE 9.2.x reads the host resolver configuration when the VM's nameserver and
search-domain fields are unset. Its automatic network output can therefore
contain host DNS/search values even though the VM configuration does not set
those fields.

For strict DHCP-only behavior, use a `cicustom` network snippet containing
only the VM NIC identity and a DHCP subnet. Do not put public resolvers or a
deployment-specific search domain in that snippet. The snippet must be stored
on a storage that supports `snippets` and must be reviewed before boot.

## Password and SSH rules

Do not set `cipassword`. Key authentication must be tested as the non-root
user, and that user must have the required administrative privilege, before a
drop-in disables password and root login.
