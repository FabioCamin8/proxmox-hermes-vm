# Security model

## Key handling

The operator supplies a public key file. The private key stays on the
operator's machine and is never copied to Proxmox, the VM, the repository, or
Cloud-Init snippets. Validate a `.pub` file against its private key before
using it.

## SSH transition

The safe sequence is:

1. connect with the requested non-root public key;
2. prove the account can run the required administrative commands without an
   interactive password prompt;
3. write a dedicated drop-in under `sshd_config.d`;
4. run `sshd -t`;
5. reload SSH while keeping the working session open;
6. test a second fresh public-key session;
7. verify the effective values:

```text
PubkeyAuthentication yes
PasswordAuthentication no
PermitRootLogin no
```

Never disable the only administrative path before the key and privilege checks
pass.

## Runtime privilege boundary

The runtime and operator paths are intentionally separate:

```text
Proxmox administrator -> operator Unix account -> sudo -> root
Hermes Agent -> unprivileged hermes -X-> sudo/root
```

Hermes has terminal access by design. If that same account has
`NOPASSWD: ALL`, it can unattendedly become root, so removing only a visible
menu option or only the direct sudo rule is insufficient. The staged
`scripts/harden-guest.sh` path removes the direct Hermes sudo entries and its
`sudo` group membership, while a managed sudoers file gives administrative
access only to the separately authenticated operator account.

## Guest network boundary

The optional nftables policy is opt-in and requires an operator-supplied SSH
source range. It accepts loopback, established/related traffic, DHCP replies,
required ICMP/ICMPv6, and explicitly scoped SSH; input and forwarding default
to drop and output remains accept. The policy contains no Hermes Gateway or
CDP ingress rule. The live policy is syntax-checked and protected by a
short-lived rollback unit before it is persisted.

## Repository hygiene

Environment files, private/public key files, VM images, tokens, credentials,
cookies, local DNS names, addresses, MACs, and storage volume IDs are ignored
or prohibited. Review `git diff --check` and search for deployment-specific
values before pushing a public repository.
