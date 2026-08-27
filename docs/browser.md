# Persistent visible Chromium

Hermes browser automation and the persistent visible browser are separate
layers:

1. Hermes browser tools use their managed Playwright/agent-browser path.
2. The desktop layer starts Debian Chromium in XFCE for a visible, persistent
   session and exposes a local CDP transport.

Computer Use is different: it attaches through `hermes-graphical` to the
actual X11/AT-SPI desktop and therefore controls the same Chromium window an
operator can see in the Proxmox noVNC console.

Do not use a normal personal Chromium profile for automation and do not
configure Browserbase, Browser Use cloud services, or browser logins in this
repository.

## Dedicated profile and startup

When `ENABLE_VISIBLE_CHROMIUM=true`, the desktop bootstrap creates an XDG data
profile at:

```text
~/.local/share/hermes/chromium-profile
```

An XFCE autostart entry launches the hermes-owned session helper. The helper
starts `/usr/bin/chromium` with:

```text
--remote-debugging-address=127.0.0.1
--remote-debugging-port=9222
--user-data-dir=$HOME/.local/share/hermes/chromium-profile
--no-first-run
--no-default-browser-check
```

The profile is separate from any default Chromium profile. The helper never
adds `--no-sandbox`; the Debian Chromium sandbox remains responsible for its
normal isolation.

## Visible browser / Computer Use workflow

The graphical bootstrap defaults to `ENABLE_AUTOLOGIN=true`, so this VM is
ready for manual console interaction after reboot. Set it to `false` only when
the LightDM greeter should remain in front. Then:

1. Open the VM's Proxmox noVNC console and confirm that XFCE/X11 and the
   visible Chromium window are available.
2. In that Chromium window, manually perform actions that should remain under
   operator control: website login, MFA, consent/cookie dialogs,
   CAPTCHA/manual verification where applicable, and account selection.
3. Leave the visible browser running unless there is a reason to close it.
   Its state is stored in the dedicated persistent profile and survives reboot
   on the VM's persistent filesystem.
4. From SSH as `hermes`, use:

   ```bash
   hermes-graphical hermes
   ```

   For diagnostics, use:

   ```bash
   hermes-graphical hermes computer-use doctor
   ```

The `hermes` account owns Hermes, Chromium, the profile, and Computer Use.
Use `ops` for apt, kernel/package administration, systemd/system services, and
`/etc`; keep `hermes` without sudo access. Browser credentials and
authenticated site state are deliberately operator-owned and are never part of
this public template.

## CDP validation

The endpoint must remain loopback-only. Do not bind it to `0.0.0.0`, add a
firewall exception, or expose port `9222` on a guest interface.

The desktop validator proves all of the following:

- the process is owned by `hermes`;
- the dedicated profile path is present and user-owned;
- the visible window is mapped in the XFCE X11 session;
- `/json/version` answers on `127.0.0.1:9222`;
- the listening socket is not on a LAN or wildcard address;
- the process command line does not contain `--no-sandbox`.

Hermes' current local-CDP detector returns the loopback URL when the browser
is running. A provider or model is not needed for this transport proof.

## Browser tool boundary

The official Hermes installer reports Playwright Chromium and its browser
dependencies separately from the visible Debian Chromium process. The
installer may resolve `agent-browser` with `npx` on first use instead of
placing a standalone `agent-browser` command on PATH. This does not change the
visible browser profile or its local CDP policy.

A real semantic browser task still requires an authenticated Hermes model
provider and is intentionally outside this repository's deployment step.
