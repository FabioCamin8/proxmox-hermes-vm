# Hermes state backup and recovery

This procedure protects persistent Hermes state with an encrypted restic
repository. It is deliberately separate from Proxmox snapshots: a VM snapshot
on the same node is not an off-host application-state backup.

The repository currently contains the reusable process and tests only. A real
backup is not considered validated until an operator supplies an approved
destination that is genuinely outside the Proxmox host.

## State boundary

The backup manifest is built from the live layout and includes:

- `/home/hermes/.hermes/.env` and `auth.json` (sensitive provider/auth state);
- `/home/hermes/.hermes/config.yaml` and `SOUL.md`;
- `state.db`, `kanban.db`, `cron/executions.db`, and any corresponding
  `-wal`/`-shm` family members;
- Hermes `pairing`, `state`, `kanban`, the `cron/executions.db` state, and (by
  default) `sessions` and `memories` directories;
- the dedicated Chromium profile, by default, excluding known browser cache
  subtrees. Cron output and runtime lock/ticker files are excluded.

The manifest excludes reproducible or ephemeral material: the Hermes source
checkout and virtual environment, browser binaries and Playwright cache,
generic logs, model/package caches, gateway locks/PIDs, terminal sandboxes,
and generated graphical-session environment. These are recreated by the
repository bootstrap and desktop procedure.

The Chromium profile contains cookies and other authentication material. It is
included only because the deployment uses persistent browser state; it must
remain encrypted and must not be launched from a restore-test tree.

The live layout was reconciled against this boundary. Additional observed
paths are intentionally excluded as follows:

- Reproducible runtime: `.hermes/hermes-agent/`, its virtual environment,
  `.hermes/node/`, `.hermes/bin/`, and `.hermes/skills/`.
- Generated or ephemeral runtime: `.config/hermes/graphical-session.env`,
  `.hermes/gateway_state.json`, `channel_directory.json`, gateway PID/lock/
  socket files, startup/history/update-check files, database rebuild/dispatch
  locks, `terminal-sessions/`, `sandboxes/`, `pending_messages/`, and
  Chromium `Singleton*` links.
- Cache or rebuildable data: `.hermes/image_cache/`, `audio_cache/`, `cache/`,
  model/provider cache files, browser cache subtrees, and Playwright caches.
- Operational logs and cron output: `.hermes/logs/`, gateway start logs, and
  `.hermes/cron/output/`.

The observed `platforms/pairing/` directory was empty; the populated Hermes
pairing directory is included above. If a future Hermes release gives that
directory persistent meaning, re-evaluate the manifest before relying on a
recovery. The manifest is deliberately explicit rather than backing up all of
`/home/hermes`.

## Tool and credential model

Restic is the selected tool because it provides authenticated encryption,
integrity checking, snapshots, include/exclude control, non-interactive use,
and native retention. The scripts do not implement cryptography or auto-create
a repository.

Install restic through the approved Debian administration process, then create
the repository and password file outside this repository. The password file
must be root-owned, mode `0600`, and outside `/home/hermes` (for example
`/etc/hermes-backup/restic-password`). Hermes must not be able to read the
credential that decrypts its own backups.

Copy `config/backup.example.env` to a root-controlled deployment path and fill
only the approved destination and password-file path. Set
`BACKUP_DESTINATION_KIND=off-host` only after confirming that the repository
leaves the guest and the physical Proxmox host. Local ZFS, local directories,
same-node PBS, and VM snapshots do not qualify.

## Consistency strategy

`backup-hermes-state.sh` requires the gateway to be healthy before starting.
It stops only the Hermes user gateway and, when the Chromium profile is
included, sends Chromium a normal `TERM` and waits for every Chromium process
to exit. It never uses `kill -9` and never stops unrelated services.

While Hermes is stopped, the script proves that the state databases have no
open process and runs read-only `PRAGMA quick_check`. It then backs up each
SQLite database together with any present WAL/SHM family members. This is a
controlled quiesced copy, not an unsafe independent copy of a live database.
The gateway and browser are restarted by the exit handler whether restic
succeeds or fails.

Restic reads the selected files directly while the processes are quiesced. It
excludes known Chromium cache subtrees but retains the profile databases and
authentication state. Full runtime, provider, browser, CDP, and Computer Use
validation must be run after the script returns.

## First backup and integrity check

From the guest through the `ops` administrative path:

```bash
install -d -m 0700 /etc/hermes-backup
install -o root -g root -m 0600 /path-provided-out-of-band/restic-password \
  /etc/hermes-backup/restic-password
restic -r '<approved-repository>' init

sudo /usr/local/libexec/backup-hermes-state.sh \
  --env /etc/hermes-backup/backup.env
sudo /usr/local/libexec/validate-backup.sh \
  --env /etc/hermes-backup/backup.env
```

The first validated snapshot must be preserved before enabling retention.
When retention is enabled, the service uses restic's native `forget --prune`
with the configured daily/weekly/monthly counts; it never deletes repository
internals manually.

The backup output records only a snapshot ID and hashes of the generated
manifest/metadata. The manifest and version record are also stored in a
separate encrypted metadata snapshot; restore selects only the tagged data
snapshot. It never prints the repository password, provider credentials,
auth-file contents, cookies, or a deployment endpoint.

## Isolated restore validation

Never restore into `/home/hermes` during validation. The restore command
requires a new absolute target under `/var/tmp/hermes-restore-test-*`, refuses
an existing or broad target, restores the selected `hermes-state` snapshot,
verifies restic data, then checks:

- expected file and directory structure;
- restored ownership and sensitive-file permissions;
- read-only SQLite `PRAGMA quick_check` for every restored database;
- YAML parsing of `config.yaml` using the installed Hermes Python environment;
- Chromium `Local State`/`Default` structure and profile permissions.

The root-owned plaintext restore tree and temporary snapshot listing are
removed automatically after validation, including on failure. The restored
Chromium profile is never launched, and restored provider credentials are
never loaded into a running service.

Example:

```bash
sudo /usr/local/libexec/restore-hermes-state.sh \
  --env /etc/hermes-backup/backup.env \
  --target /var/tmp/hermes-restore-test-20260826
```

The target name must match the command's `/var/tmp/hermes-restore-test-*`
cleanup policy. A future replacement VM should first be built with the same
Debian major version, Hermes version/source commit, `cua-driver` version, and
compatible Chromium version recorded in the backup metadata. Restore state
only after the runtime is installed and quiesced. Do not blindly restore
across Hermes config/database schema changes or incompatible Chromium versions;
upgrade separately after a same-version recovery works.

## Recovery sequence

1. Create a fresh Debian VM and apply the repository Cloud-Init/base setup.
2. Install the desktop, Chromium, Hermes, and least-privilege hardening.
3. Reconstruct the compatible versions recorded by the backup metadata.
4. Configure the approved restic repository and root-controlled password file.
5. Stop/quiesce the fresh Hermes runtime and browser.
6. Restore persistent state into the intended new guest paths only after the
   isolated restore validation passes.
7. The isolated restore normalizes the restored tree to the target system's
   unprivileged `hermes:hermes` identity before validating ownership. Never
   make sensitive files group/world readable.
8. Start the graphical session, Chromium, and Hermes gateway.
9. Validate provider access, browser semantic smoke, loopback-only CDP,
   Computer Use, gateway health, and failed systemd units.

Do not restore the backup password file, a private SSH key, or a Proxmox
snapshot as application state. Destination values and secrets remain external
configuration and are not represented in Git.

## Automation

After the first manual backup, install the supplied
`systemd/hermes-state-backup.service` and `.timer` as root, copy the scripts to
`/usr/local/libexec` (including `scripts/lib/hermes-backup.sh` under a `lib`
subdirectory), and enable the timer. The service runs as root because it must
coordinate the unprivileged gateway/browser and protect the decryption
credential; Hermes is never the backup service identity. Review the actual
state churn and destination capacity before retaining the example daily
schedule. Validate a fresh snapshot and restore before relying on automation.

## Current validation boundary

The live Hermes baseline is known healthy, but no approved genuinely off-host
destination was available during this implementation. Therefore no sensitive
state was exported, no restic package/credential was installed, no backup was
created, and no restore was claimed. The remaining operator input is an
approved off-host restic repository plus its out-of-band password file.
