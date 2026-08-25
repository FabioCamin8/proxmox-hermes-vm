# Architecture

```text
Proxmox VE
└── Debian 13 generic cloud VM
    ├── Cloud-Init
    ├── OpenSSH
    ├── QEMU Guest Agent option + guest package
    │
    └── guest runtime layer
        ├── Hermes Agent
        ├── Chromium
        └── lightweight XFCE/X11 desktop
```

## Why a VM

The complete Hermes browser/computer-use stack needs a normal Linux kernel,
graphical session, browser sandbox, accessibility interfaces, and a console
that an operator can inspect. A VM provides those boundaries without coupling
the application to the Proxmox host or to a container's host kernel.

## Layer ownership

- Proxmox owns CPU, memory, firmware, disks, virtual NICs, and the console.
- Cloud-Init owns first-boot identity, hostname, SSH key injection, and basic
  network initialization.
- The base validation layer proves the operating system and administrative
  access before any application layer is installed.
- The guest runtime scripts own Hermes, the dedicated browser profile, the
  desktop session, and automation dependencies.

Keeping the application layer separate makes a failed browser bootstrap
recoverable without changing the VM identity or base access path.
