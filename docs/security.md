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

## Repository hygiene

Environment files, private/public key files, VM images, tokens, credentials,
cookies, local DNS names, addresses, MACs, and storage volume IDs are ignored
or prohibited. Review `git diff --check` and search for deployment-specific
values before pushing a public repository.
