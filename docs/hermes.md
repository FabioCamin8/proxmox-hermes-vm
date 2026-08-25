# Hermes Agent runtime

The Hermes layer is installed only as the unprivileged `hermes` user. The
repository does not configure a model provider, OAuth account, messaging
platform, browser login, or application secret.

## Official installer

The current supported Linux method is the official installer:

```text
https://hermes-agent.nousresearch.com/install.sh
```

`scripts/bootstrap-hermes.sh` downloads the installer to a temporary file,
checks that its current `--skip-setup`, browser, and Computer Use controls are
present, then delegates execution to `hermes` with `--skip-setup`. It never
passes `--skip-browser` or `--skip-computer-use`.

Set `HERMES_COMMIT` to a full Git SHA when a reproducible source snapshot is
required:

```bash
sudo env \
  HERMES_USER=hermes \
  HERMES_COMMIT=<official-hermes-commit> \
  ./scripts/bootstrap-hermes.sh
```

The script writes a non-secret receipt to:

```text
~/.hermes/hermes-install-receipt
```

The normal per-user layout is:

```text
~/.hermes/hermes-agent/
~/.hermes/hermes-agent/venv/
~/.local/bin/hermes
```

The official installer manages uv, Python, Node.js, ripgrep, ffmpeg, browser
dependencies, and a best-effort cua-driver installation. It may install
system prerequisites through the user's authorized sudo capability; do not
preinstall a separate Python or Node runtime just for Hermes.

## Validation

Run as `hermes`:

```bash
./scripts/validate-hermes.sh
```

The validator checks the managed source revision and virtual environment,
Hermes version/help, Python/Node/ripgrep/ffmpeg/cua-driver, `hermes doctor`,
Computer Use status/doctor, and the Playwright browser cache when a graphical
session environment is available.

The current validated snapshot was Hermes `0.20.5`, source commit
`1bbb6e5bce56e721ab685af4cd87df21bbff4d35`, cua-driver `0.22.0`, Python
`3.11.16`, Node `v26.7.0`, ripgrep `14.1.1`, and Debian Chromium
`151.0.7922.169-1~deb13u1`. These are observations from one install, not
permanent public version pins.

`hermes doctor` exited zero in the validated guest. It still reported the
expected unconfigured provider/auth warnings, an available config migration,
state-database schema warnings, optional workspace dependency advisories, and
optional browser-system-dependency warnings. The task deliberately did not run
`hermes doctor --fix` or configure any provider.

`hermes computer-use doctor` is the current Computer Use diagnostic. In the
validated X11 session it exited zero and reported a live cua-driver MCP
session, AT-SPI reachability, X11 input, and functional screen capture.

## SSH and graphical sessions

An SSH shell is not evidence that `DISPLAY`, `XAUTHORITY`,
`DBUS_SESSION_BUS_ADDRESS`, or AT-SPI refer to the LightDM session. Use the
desktop-generated `hermes-graphical` wrapper or run Hermes from the actual
XFCE session. The wrapper loads the captured graphical environment and is the
intended bridge for provider-free diagnostics launched over SSH.

No semantic Hermes task was run because that would require model/provider
credentials. The transport and Computer Use readiness proof is independent of
that manual step.
