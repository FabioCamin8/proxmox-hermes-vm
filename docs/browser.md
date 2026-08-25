# Persistent visible Chromium

Hermes browser automation and the persistent visible browser are separate
layers:

1. Hermes browser tools use their managed Playwright/agent-browser path.
2. The desktop layer starts Debian Chromium in XFCE for a visible, persistent
   session and exposes a local CDP transport.

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
