# Cloud-Init templates

These files are small templates for the base operating-system handoff. They
are deliberately not an application installer.

The intended defaults are:

- user `hermes` with a public SSH key;
- DHCP for IPv4;
- no configured login password;
- package upgrades disabled during first boot;
- hostname supplied by the VM configuration;
- IPv6 left to the image and network defaults.

The `${...}` markers must be rendered before the files are supplied directly
to Cloud-Init. The Proxmox CLI path can avoid rendering user-data by using
`qm set` with `--ciuser`, `--sshkeys`, `--ipconfig0 ip=dhcp`, and
`--ciupgrade 0`.

Application provisioning is intentionally separate. Hermes, a desktop, and a
browser should be installed only after the base VM passes validation.
