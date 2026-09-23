# Security

## Non-root, no capabilities

The container runs as an unprivileged user (`orca`, UID/GID 1000 by default), never as
root, and the compose file additionally applies:

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
```

Both were verified compatible with the default configuration. Combined with Docker's
default seccomp profile, that is a meaningfully smaller blast radius than running as
root.

## About `--no-sandbox`

`ORCA_NO_SANDBOX=true` is the default because it is the **only configuration that
works in an unmodified container**, and the reason is structural rather than cosmetic:

- Chromium's SUID sandbox helper (`chrome-sandbox`, root-owned, mode 4755) needs
  `CAP_SYS_ADMIN` to create its PID and network namespaces. Docker's default capability
  bounding set does not include `CAP_SYS_ADMIN`, and the bounding set is not regained
  through setuid. The helper therefore fails with `Failed to move to new namespace`.
- The user-namespace sandbox is also unavailable by default: Docker's seccomp profile
  gates `unshare`/`setns` behind `CAP_SYS_ADMIN`, and on Ubuntu 23.10+ hosts the
  kernel's AppArmor unprivileged-userns restriction blocks it too.
- `no-new-privileges` disables setuid elevation outright, and `cap_drop: ALL` empties
  the bounding set — so both hardening options above are mutually exclusive with a
  working sandbox.

Upstream says the same thing from the other direction: running the AppImage as root
requires `--no-sandbox`, and a dedicated unprivileged service user is preferred. This
image drops the Chromium sandbox but keeps the process unprivileged, which still
bounds what a compromised renderer can touch.

**If you want the real sandbox**, drop the two hardening options and grant the
capability the helper needs:

```yaml
services:
  orca:
    environment:
      ORCA_NO_SANDBOX: "false"
    cap_add: [SYS_ADMIN]
    security_opt: []      # remove no-new-privileges
    # cap_drop: []        # remove this too
```

On an Ubuntu 24.04 host you may additionally need a seccomp profile that allows
`unshare`/`setns`, or `kernel.apparmor_restrict_unprivileged_userns=0`. This is the
path Playwright and Puppeteer document for non-root containers; decide deliberately.

## Secrets are stored unencrypted

Orca logs this on every start in a container:

```
[secrets] The OS keyring is unavailable, so secrets are stored unencrypted.
```

There is no unlocked D-Bus session keyring in a headless container, so Orca falls back
to storing secrets in the state directory in plaintext. Anyone who can read that
volume or directory can read them. Restrict access to it, and prefer
environment-based credentials for the agent CLIs where the tool supports it.

## Do not expose the port publicly

The runtime is a WebSocket control plane for terminals and agents. Upstream recommends
Tailscale, WireGuard, a trusted LAN, SSH forwarding, or an authenticated tunnel.
Port-forwarding `6768` to the internet is not a supported configuration.

If you need TLS, terminate it at a reverse proxy and advertise the `https://` URL as
`ORCA_PAIRING_ADDRESS` — Orca normalises it to `wss://`. The proxy must support
WebSocket upgrade.

## Running agent CLIs safely

The image does not include the coding agents; you install them. Whatever you install
runs as the same unprivileged user as Orca, inside the same container, with access to
the same volume. Treat an agent CLI as code you are trusting with your repositories
and credentials.

Agent authentication lives in the state volume. Because there is no keyring, those
tokens are stored unencrypted — see above.
