# Networking

The generic default is:

```text
bridge: <BRIDGE>
model: VirtIO
IPv4: DHCP
IPv6: image/network default
MTU: 1500
DNS: DHCP/inherited behavior
search domain: unset
```

`MTU=1500` is deliberately conservative for a public repository. Jumbo
frames require every link in the path to support the same value. The scripts
do not alter bridges, physical interfaces, VLANs, or storage configuration.

## Address identity

An address is valid evidence only when correlated to the VM's configured NIC
MAC, QEMU Guest Agent output, or a trusted DHCP/neighbor record. A responsive
ping is not enough because another guest can answer it.

## PVE DNS fallback

When `nameserver` and `searchdomain` are absent, PVE 9.2.x can serialize the
host resolver and search values into its automatically generated network
configuration. This is a verified PVE behavior, not a generic DHCP guarantee.

If the requirement is to let DHCP provide DNS with no static search block,
use a reviewed `cicustom` network snippet containing only DHCP configuration.
