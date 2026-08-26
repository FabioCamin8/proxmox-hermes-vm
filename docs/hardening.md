# Guest hardening

This repository keeps the Hermes runtime account separate from the operator
administration path:

```text
Proxmox administrator
        |
        | provisioning / recovery
        v
separate operator Unix account
        |
        | sudo
        v
      root

Hermes Agent
        |
        v
unprivileged hermes
        X
      sudo/root
```

An account with terminal access plus `NOPASSWD: ALL` has unattended root
capability. The hardening entry point removes both the direct Hermes sudo rule
and its membership in the `sudo` group. It does not replace that access with a
large Hermes allowlist.

## Configuration

Copy `config/hardening.example.env` to a private operator file. Supply the
operator's public key in `ADMIN_SSH_PUBLIC_KEY_FILE`; the private key stays on
the operator machine. The firewall remains disabled unless
`ENABLE_FIREWALL=true` and an explicit `SSH_ALLOWED_CIDR` or
`SSH_ALLOWED_IPV6_CIDR` is supplied. The script never guesses a management
range.

The default `ADMIN_USER=ops` is safe to change if that local name already
exists. The script refuses to take over an unrelated existing account.

## Firewall ownership

The optional firewall is intended for a dedicated guest whose complete
nftables policy can be owned by this repository. The repository does not merge
with arbitrary existing firewall policies. Before applying or persisting a
policy, the script requires either a clean ruleset and an empty or absent
configuration file, the exact stock Debian empty `inet filter` configuration,
or a root-owned managed-state marker whose hashes and contents still match the
repository policy. Unmanaged or ambiguous rules are refused, and
`/etc/nftables.conf` is not overwritten in that case. The stock configuration
is takeover-safe only when the live ruleset is empty; a loaded table still
requires the managed-state proof or explicit adoption.

Do not enable the firewall blindly on an already-managed system. For the
already-hardened guest, first render and prove the live ruleset and persistent
configuration with the explicit adoption stage. Adoption records the managed
state only after that proof and does not reapply nftables:

```text
sudo bash scripts/harden-guest.sh --env /path/to/private-hardening.env --stage adopt
```

If the live policy or configuration does not exactly match the generated
repository policy, stop and review it manually; there is no automatic merge
path.

## Staged application

Run the scripts inside the guest as root, normally through the current
bootstrap account while it still has administrative access:

```text
sudo env ADMIN_SSH_PUBLIC_KEY_FILE=/path/to/operator.pub \
  bash scripts/harden-guest.sh --env /path/to/private-hardening.env --stage operator
```

Open a completely new SSH session as the operator and prove `sudo -n true`,
`sudo id`, `sudo systemctl status ssh`, and `sudo visudo -c`. From that fresh
session, run the privilege stage. The script requires `SUDO_USER` to be the
configured operator, so a console/root invocation cannot accidentally bypass
this recovery-path proof:

```text
sudo bash scripts/harden-guest.sh --env /path/to/private-hardening.env --stage privilege
```

The network stage writes a minimal systemd-resolved drop-in with `LLMNR=no`.
When enabled, its nftables policy allows loopback, established/related
traffic, DHCP replies, required ICMP/ICMPv6, and SSH only from the explicit
operator ranges. Input and forwarding default to drop; output remains accept.
It does not add an exception for Hermes Gateway or CDP. OUTPUT remains accept
by design, and CDP must still be bound to loopback (`127.0.0.1`); the firewall
is not a substitute for that binding. When the explicitly enabled firewall has
no `nft` command, the script installs only Debian's `nftables` package before
applying the policy.

The firewall is first syntax-checked and loaded only in memory. Before load,
the current ruleset is saved and a short-lived systemd rollback unit is
created. Keep the operator session open, open a second fresh operator SSH
session after the live load, and then persist the tested policy:

```text
sudo bash scripts/harden-guest.sh --env /path/to/private-hardening.env --stage network
# new SSH session and connectivity proof
sudo bash scripts/harden-guest.sh --env /path/to/private-hardening.env --stage finalize
```

If the new connection fails, leave the rollback timer running and recover via
the Proxmox console or the still-open operator session. Do not cancel the
timer until a fresh SSH session has succeeded.

The `finalize` stage replaces `/etc/nftables.conf` only for the clean-firewall
transition staged by `network`, after rechecking the live policy. A previously
managed policy may be finalized without another load; any other existing
configuration is refused.

## Validation

`scripts/validate-hardening.sh` is read-only. It checks the operator account,
key file shape and permissions, managed sudo policy, Hermes' effective sudo
denial and failed sudo path, effective SSH policy, LLMNR/DNS, optional
nftables ownership and exact policy persistence, gateway activity when a
gateway has been configured, and loopback CDP. A pristine
official Hermes install reports `gateway=NOT_CONFIGURED`; an installed but
inactive gateway remains a validation failure. Run provider and graphical smoke tests from the
actual Hermes SSH session, where the captured XFCE environment is available:

```text
hermes-graphical hermes computer-use doctor
hermes-graphical hermes -z 'Use the browser tool to navigate to https://example.com. Return exactly two lines: title=<document title> and heading=<main heading>.' -t browser
```

The root hardening validator does not impersonate the desktop session for
these provider/browser calls. It does not print keys, `.env` files, browser
profiles, or Hermes state. A provider smoke remains an explicit live check
because its availability and cost are external runtime facts.

## LLMNR recovery

LLMNR is disabled because the validated guest did not require it and it opened
UDP/TCP port 5355 on all addresses. Set `ENABLE_LLMNR=true` and rerun the
network stage to remove the managed drop-in and restart systemd-resolved. Then
verify DNS and the reason for re-enabling it.
