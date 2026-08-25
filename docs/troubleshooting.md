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
the guest package. Report the distinction. Install only the narrowly required
package in a separately approved task.

## SSH lockout risk

Keep a working session, verify `sudo -n`, validate with `sshd -t`, reload
rather than reboot solely for SSH, and test a second session before closing
the original one.

## MTU mismatch

Inspect the bridge, tap, virtual NIC, and guest interface. Do not force jumbo
frames from inside the guest without proving the complete network path.
