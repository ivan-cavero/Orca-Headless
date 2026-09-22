# Orca Headless Docker

[![Build and publish image](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Image: ghcr.io](https://img.shields.io/badge/ghcr.io-orca--headless-blue?logo=docker&logoColor=white)](https://github.com/ivan-cavero/orca-headless/pkgs/container/orca-headless)
[![Orca](https://img.shields.io/badge/orca-v1.4.206-black)](https://github.com/stablyai/orca/releases)

Run [Orca](https://www.onorca.dev) — the agent development environment — on a Linux
server with **no desktop session**: a VPS, a build box, a VM, a home server.

Orca ships a `serve` mode that runs the full runtime without opening a window, but
getting it there by hand means installing a specific set of Electron libraries,
working around a missing FUSE device, arranging a virtual X display, and keeping
the thing alive across reboots. This repository packages all of that into one
image and one `docker-compose.yml`, so the deployment is:

```bash
cp .env.example .env      # set ORCA_PAIRING_ADDRESS
mkdir -p workspace
docker compose up -d
```

What you get:

- **Headless by construction.** No FUSE, no `--privileged`, no `xvfb-run` wrapper,
  no desktop packages. Orca manages its own virtual display.
- **Runs unprivileged.** A dedicated non-root user, with `cap_drop: ALL` and
  `no-new-privileges` applied.
- **Persistent.** Projects, worktrees, terminal history and paired-device keys
  survive `docker compose down`, image upgrades, and even a `SIGKILL`.
- **Configurable by environment.** Port, pairing address, UID/GID, JSON contract.
- **Verifiable.** The healthcheck parses Orca's own versioned readiness contract
  instead of just poking the TCP port.

> Remote Orca Servers are **beta** upstream. Keep the listener on a private
> network path you control — Tailscale, WireGuard, a trusted LAN, or an
> authenticated tunnel. Do not expose it to the public internet.

---

## Contents

- [Quick start](#quick-start)
- [Connecting a client](#connecting-a-client)
- [Configuration](#configuration)
- [Volumes](#volumes)
- [Updating](#updating)
- [Security](#security)
- [Running agent CLIs](#running-agent-clis)
- [Building the image yourself](#building-the-image-yourself)
- [Image size](#image-size)
- [What was verified](#what-was-verified)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)

---

## Quick start

Requirements: Docker Engine 20.10+ with the Compose plugin, on a 64-bit Linux host
(`amd64` or `arm64`). No GPU, no display, no FUSE.

```bash
git clone https://github.com/ivan-cavero/orca-headless.git
cd orca-headless

cp .env.example .env
$EDITOR .env                     # at minimum: ORCA_PAIRING_ADDRESS

mkdir -p workspace               # do this first, so you own the directory
docker compose up -d
```

Watch it come up:

```bash
docker compose logs -f orca
```

Within a few seconds Orca prints its readiness contract:

```json
{"type":"orca_server_ready","schemaVersion":1,"runtimeId":"...",
 "endpoint":"ws://0.0.0.0:6768","boundEndpoint":"ws://0.0.0.0:6768",
 "advertisedEndpoint":"ws://100.64.1.20:6768",
 "pairing":{"available":true,"url":"orca://pair?code=...","scope":"runtime"}}
```

(The real output is a single compact line.)

Copy the `pairing.url` value — that is what you paste into the client.

Confirm the container is healthy:

```bash
docker compose ps
# NAME   STATUS
# orca   Up 2 minutes (healthy)
```

### With rootless Podman instead of Docker

Rootless Podman maps your host UID to container UID 0, so the bind-mounted
workspace ends up root-owned inside the container and the unprivileged `orca`
user cannot write to it. Add the Podman overlay, and on an SELinux host also set
`ORCA_SELINUX_LABEL=:z`:

```bash
podman-compose -f docker-compose.yml -f docker-compose.podman.yml up -d
```

---

## Connecting a client

On your laptop, open Orca and go to **Settings → Remote Orca Servers → Add
Server**, then paste the `pairing.url` from the logs:

```bash
docker compose logs orca | grep -o 'orca://pair?code=[^"]*' | tail -1
```

The client dials `ORCA_PAIRING_ADDRESS`, so it must be an address the client can
actually reach:

| Where the client runs | `ORCA_PAIRING_ADDRESS` |
| --- | --- |
| Same Tailscale tailnet | the server's `100.x.y.z` address |
| Same LAN | the server's LAN IP, e.g. `192.168.1.40` |
| Public DNS name | `orca.mydomain.dev` |
| Behind a TLS reverse proxy | `https://orca.example.com/runtime` |

`--pairing-address` is only *advertised*; it never changes where Orca listens.
Inside the container Orca always binds `0.0.0.0`, and Compose publishes the port.

Three things will silently break a connection:

1. **`127.0.0.1`.** The pairing URL then points at the *client's* own loopback.
   The entrypoint warns about this at startup.
2. **A firewall.** Open `ORCA_PORT` (default `6768`) for the client's source.
3. **A reverse proxy without WebSocket upgrade.** The runtime speaks WebSocket,
   not HTTP; the proxy must forward the `Upgrade`/`Connection` headers and route
   the advertised path. Advertise `https://…` when TLS terminates at the proxy —
   Orca normalises it to `wss://`.

The pairing URL contains a device credential and E2EE material. Treat it like a
password, and revoke grants you no longer need from **Shared Server Access** on
the server side.

---

## Configuration

Every variable is optional; the defaults produce a working container. Copy
`.env.example` to `.env` and edit.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ORCA_PAIRING_ADDRESS` | `127.0.0.1` | **Set this.** Address clients dial. A hostname, IP, Tailscale address, or full `https://` reverse-proxy URL. Wildcards (`0.0.0.0`, `*`, `::`) are rejected at startup. |
| `ORCA_PORT` | `6768` | Port Orca listens on inside the container. Compose publishes the same value on the host. |
| `ORCA_IMAGE` | `ghcr.io/ivan-cavero/orca-headless:latest` | Image to run. Change it if you forked or build locally. |
| `PUID` / `PGID` | `1000` / `1000` | UID/GID the container runs as. **Build-time** arguments; see [Changing PUID/PGID](#changing-puidpgid). |
| `ORCA_WORKSPACE` | `./workspace` | Host directory mounted at `/home/orca/workspace`. |
| `ORCA_SELINUX_LABEL` | *(empty)* | `:z` on SELinux hosts (Fedora/RHEL/CentOS). Empty elsewhere. |
| `ORCA_JSON` | `true` | `true` emits the versioned single-line JSON contract; `false` emits the human-readable `Orca server ready` block. |
| `ORCA_NO_SANDBOX` | `true` | Adds Chromium's `--no-sandbox`. Read [Security](#security) before changing. |
| `ORCA_EXTRA_ARGS` | *(empty)* | Extra flags appended to `orca serve`, e.g. `--mobile-pairing`. |
| `ORCA_VERSION` | `v1.4.206` | Orca release baked in. Only read when building locally. |

Inside the container these are set as `ENV` as well, so `docker compose exec orca
sh` sees them.

---

## Volumes

| Container path | Recommended | Why |
| --- | --- | --- |
| `/home/orca/.config` | named volume `orca-config` | All persisted state: projects, worktree metadata, terminal history, orchestration state, and paired-device keys. Orca uses **both** `~/.config/orca` and `~/.config/Orca`, so mount the parent directory. |
| `/home/orca/workspace` | bind mount, e.g. `./workspace` | Your repositories. Orca records absolute paths in its state, so **keep this path stable** — moving it invalidates existing worktree entries. |

Do not mount the same named volume at both `~/.config/orca` and `~/.config/Orca`.
Docker would present the same directory contents at both paths, which is not what
Orca expects. Mounting the parent is correct.

Back up the state volume with:

```bash
docker run --rm -v orca-headless_orca-config:/data -v "$PWD":/backup \
  alpine tar czf /backup/orca-state-$(date +%F).tgz -C /data .
```

---

## Updating

`orca serve` never updates itself — upstream is explicit that headless mode wires
up no auto-updater. Upgrading means replacing the image and restarting.

```bash
docker compose pull
docker compose up -d
```

Your state lives in the `orca-config` volume, not next to the binary, so
projects, worktrees, terminal history and paired-device keys survive. Mobile and
web clients reconnect without re-pairing. New builds migrate older state on load.

**Live processes do not survive.** A restart kills every terminal and agent in
the container; conversations may be resumable, but in-flight commands are gone.

To pin a specific Orca release rather than track `latest`, build locally:

```bash
ORCA_VERSION=v1.4.206 docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### Rolling back

A newer build may rewrite `orca-data.json` in a newer schema, and an older build
can then discard fields it does not recognise. Roll back the **state volume and
the image together** — restoring the image alone is not safe:

```bash
docker compose down
# restore the orca-config volume from a backup taken before the upgrade
ORCA_IMAGE=ghcr.io/ivan-cavero/orca-headless:1.4.200 docker compose up -d
```

---

## Security

### Non-root, no capabilities

The container runs as an unprivileged user (`orca`, UID/GID 1000 by default),
never as root, and `docker-compose.yml` additionally applies:

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
```

Both were verified compatible with the default configuration. Combined with
Docker's default seccomp profile and a read-only host filesystem outside the two
mounted paths, that is a meaningfully smaller blast radius than running as root.

### About `--no-sandbox`

`ORCA_NO_SANDBOX=true` is the default because it is the **only configuration that
works in an unmodified container**, and the reason is structural rather than
cosmetic:

- Chromium's SUID sandbox helper (`chrome-sandbox`, root-owned, mode 4755) needs
  `CAP_SYS_ADMIN` to create its PID and network namespaces. Docker's default
  capability bounding set does not include `CAP_SYS_ADMIN`, and the bounding set
  is not regained through setuid. The helper therefore fails with
  `Failed to move to new namespace`.
- The user-namespace sandbox is also unavailable by default: Docker's seccomp
  profile gates `unshare`/`setns` behind `CAP_SYS_ADMIN`, and on Ubuntu 23.10+
  hosts the kernel's AppArmor unprivileged-userns restriction blocks it too.
- `no-new-privileges` disables setuid elevation outright, and `cap_drop: ALL`
  empties the bounding set — so both hardening options above are mutually
  exclusive with a working sandbox.

Upstream says the same thing from the other direction: running the AppImage as
root requires `--no-sandbox`, and a dedicated unprivileged service user is
preferred. This image does exactly that — it drops the Chromium sandbox but keeps
the process unprivileged, which still bounds what a compromised renderer can
touch.

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
`unshare`/`setns`, or the kernel setting
`kernel.apparmor_restrict_unprivileged_userns=0`. This is the path Playwright and
Puppeteer document for non-root containers, and it trades security surface for
security hardening — decide deliberately.

### Secrets are stored unencrypted

Orca logs this on every start in a container:

```
[secrets] The OS keyring is unavailable, so secrets are stored unencrypted.
```

There is no unlocked D-Bus session keyring (gnome-keyring/kwallet) in a headless
container, so Orca falls back to storing secrets in the state volume in plaintext.
Anyone who can read the `orca-config` volume can read them. Restrict access to
that volume, and prefer environment-based credentials for the agent CLIs where
the tool supports it.

### Do not expose the port publicly

The runtime is a WebSocket control plane for terminals and agents. Upstream
recommends Tailscale, WireGuard, a trusted LAN, SSH forwarding, or an
authenticated tunnel. Port-forwarding `6768` to the internet is not a supported
configuration.

---

## Running agent CLIs

The image contains Orca and its dependencies, **not** the coding agents. Orca
shells out to `codex`, `claude`, `opencode` and friends, so a missing binary
shows up like this on startup:

```
[codex-trust-grant] falling back to self-computed trust (reason=error, host=native)
Error: spawn codex ENOENT
```

Orca still becomes ready and clients still connect — but that agent cannot run.
Install the CLIs where Orca can find them. Two options:

**Mount a host directory that already has them** (simplest; the binaries must be
built for the container's libc):

```yaml
volumes:
  - /home/you/.local/bin:/home/orca/.local/bin:ro
```

**Or build a derived image** — the reproducible option:

```dockerfile
FROM ghcr.io/ivan-cavero/orca-headless:latest
USER root
# Node is needed by most agent CLIs and by `orca skills install`.
RUN apt-get update && apt-get install -y --no-install-recommends nodejs npm \
 && rm -rf /var/lib/apt/lists/*
USER orca
RUN npm install -g @anthropic-ai/claude-code @openai/codex
```

Then authenticate from a shell inside the container, since a login on your laptop
does not carry over:

```bash
docker compose exec orca sh
orca-ide account add --agent claude
orca-ide account add --agent codex
orca-ide account list
```

Skills install the same way, without a Settings UI:

```bash
orca-ide skills install --skill orca-cli --skill orchestration
orca-ide skills update --all
```

The registered CLI is **`orca-ide`**, not `orca` — the name avoids shadowing the
GNOME Orca screen reader. `orca serve` also writes a best-effort bare `orca`
dispatcher into `~/.local/bin`.

---

## Building the image yourself

```bash
docker build -t orca-headless:local .
```

Useful build arguments:

| Argument | Default | Purpose |
| --- | --- | --- |
| `ORCA_VERSION` | `v1.4.206` | Orca release to download. `latest` works but is not reproducible. |
| `PUID` / `PGID` | `1000` / `1000` | UID/GID of the `orca` user. Must be ≥ 1000. |
| `ORCA_USER` | `orca` | Name of the unprivileged user. |
| `ORCA_EXTRA_PACKAGES` | *(empty)* | Extra apt packages, space-separated. |
| `UBUNTU_VERSION` | `24.04` | Base image tag. |

The build is two stages: the AppImage is downloaded and extracted in a throwaway
stage, and only the extracted tree is copied into the runtime image. That is why
FUSE is never needed, and why the ~190 MB AppImage never occupies a layer of the
image you actually run.

The base is `ubuntu:24.04` because it is on Orca's supported matrix and upstream
publishes the exact package list for it. Debian 13+ works too but is not what the
image is tested against.

### Changing PUID/PGID

PUID and PGID are **build-time** values, so the container's `user:` must match
the image's build arguments. If you change one and not the other, the state
volume is owned by a different UID and Orca cannot persist anything — the
entrypoint will warn you.

```bash
PUID=1500 PGID=1500 docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

If you already have a state volume from a previous UID, fix its ownership:

```bash
docker compose down
docker run --rm -v orca-headless_orca-config:/data alpine chown -R 1500:1500 /data
docker compose up -d
```

---

## Image size

The published image is roughly **1.1 GB** on disk. That is normal for
an Electron/Chromium application, and most of it is not this Dockerfile's doing:

| Layer | Size | What it is |
| --- | --- | --- |
| Extracted Orca app | ~568 MB | Chromium runtime + Orca's application resources |
| System libraries | ~470 MB | The Electron dependency set. `libgbm1` alone pulls `mesa-libgallium` → `libllvm20` (~178 MB), which cannot be dropped without breaking Electron. `git` pulls ~55 MB of Perl. |
| Ubuntu base | ~81 MB | `ubuntu:24.04` |

What this repository *did* optimise: a multi-stage build keeps the 192 MB
AppImage out of the final image entirely, `--no-install-recommends` is used
throughout, `apt-get update` and `install` share a single layer, and the apt
lists are removed in that same layer. Aggressive trimming (dropping unused
Electron locales, for example) was deliberately **not** applied — it saves about
4% and risks breaking localisation for no real benefit.

---

## What was verified

Honest accounting. The following were executed against the built image on
**Podman 5.8.7 / Fedora 44, x86_64**, not merely reasoned about:

| Check | Result |
| --- | --- |
| Image builds from a clean base | ✅ |
| Container reaches `healthy` via its own `HEALTHCHECK` | ✅ ~15–35 s after start |
| Orca emits `{"type":"orca_server_ready","schemaVersion":1,…}` | ✅ |
| Human-readable `Orca server ready` block with `ORCA_JSON=false` | ✅ |
| Healthcheck passes in both JSON and text modes | ✅ |
| No FUSE, no `--privileged`, no `xvfb-run` | ✅ Orca starts its own Xvfb |
| Binds `ws://0.0.0.0:6768`, reachable from the host | ✅ |
| State survives destroy + recreate of the container | ✅ marker file persisted |
| State survives `SIGKILL` followed by restart | ✅ stale `SingletonLock` recovered |
| Graceful `SIGTERM` shutdown | ✅ exit 0, immediate |
| `cap_drop: ALL` + `no-new-privileges` | ✅ still reaches ready |
| Wildcard `ORCA_PAIRING_ADDRESS` rejected at startup | ✅ exit 1, clear message |
| Non-numeric `ORCA_PORT` rejected at startup | ✅ exit 1 |
| `docker-compose.yml` parses and runs end to end | ✅ via `podman-compose` |
| Rootless Podman workspace fix (`keep-id` + `:z`) | ✅ verified writable |

**Not verified here, and worth knowing:**

- The GHCR publish workflow has not been executed; GitHub Actions was not
  available in the environment where this repository was assembled. The action
  versions are current as of the pinned majors, and the `smoke-test` job mirrors
  the exact steps verified above.
- `arm64` is built by CI but was not tested on real hardware. `amd64` is the
  tested target.
- Docker Engine itself was not used — Podman was. Compose semantics are shared,
  but if you hit a Docker-specific difference, it is a bug worth reporting.

---

## Troubleshooting

### The client cannot connect

Nine times out of ten it is `ORCA_PAIRING_ADDRESS`. Check what was advertised:

```bash
docker compose logs orca | grep -o '"advertisedEndpoint":"[^"]*"' | tail -1
```

That value is what the client dials. If it says `127.0.0.1`, or an address the
client cannot route to, fix `.env` and `docker compose up -d`. Then confirm the
port is actually reachable from outside:

```bash
nc -z <server-ip> 6768 && echo open
```

Behind a reverse proxy, remember it must support WebSocket upgrade and route the
advertised path.

### `spawn codex ENOENT` (or `spawn claude`)

The agent CLI is not installed in the container. Orca starts and serves fine, but
that agent cannot be launched. See
[Running agent CLIs](#running-agent-clis). This is the single most common
first-run surprise.

### `dlopen(): error loading libfuse.so.2`

You are running an AppImage directly without FUSE. This image never hits that
path — it extracts the AppImage at build time and runs the extracted tree, so
`libfuse2` is not needed at all. If you see this while running the AppImage
yourself, either install `libfuse2` (Ubuntu 22.04) / `libfuse2t64` (Ubuntu
24.04) or use `--appimage-extract` once and run `squashfs-root/AppRun`.

### `Permission denied` on `/home/orca/workspace`

Two distinct causes:

- **Rootless Podman.** Your host UID maps to container UID 0, so the bind mount
  is root-owned inside the container. Use the Podman overlay:
  `podman-compose -f docker-compose.yml -f docker-compose.podman.yml up -d`.
- **SELinux host.** Unix permissions look correct but the label blocks writes.
  Set `ORCA_SELINUX_LABEL=:z` in `.env`.

The entrypoint prints a warning naming the directory when it detects this.

### State does not persist after `down`

Check that the container actually got the volume:

```bash
docker inspect orca --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
```

If you overrode `user:` to a UID different from the image's `PUID`, the volume is
owned by someone else and Orca silently fails to write. See
[Changing PUID/PGID](#changing-puidpgid).

### `Another Orca instance is already running for this userData profile`

Orca exits with status **3** when something else already owns the same userData
profile. Find the owner, stop it, and restart. If nothing owns it, the lock is
stale — remove `SingletonLock` and `SingletonSocket` from the state volume:

```bash
docker compose down
docker run --rm -v orca-headless_orca-config:/data alpine \
  rm -f /data/orca/SingletonLock /data/orca/SingletonSocket
docker compose up -d
```

This was tested: a `SIGKILL` leaves those files behind and Orca recovers from
them on the next start. You should not normally need this.

### D-Bus errors fill the log

```
ERROR:dbus/bus.cc:406] Failed to connect to the bus: ... /run/dbus/system_bus_socket
```

Expected and harmless on a headless host. Orca does not need a session D-Bus to
serve. The line that matters is `orca_server_ready`.

### `[secrets] The OS keyring is unavailable`

Also expected — see [Security](#security). Secrets are stored unencrypted in the
state volume.

### The container is `unhealthy` but clients work

The healthcheck requires Orca's readiness line in `/tmp/orca-serve.log` **and** an
open listener. If you changed `ORCA_EXTRA_ARGS` or set `ORCA_JSON` to something
other than `true`/`false`, check the log:

```bash
docker compose exec orca cat /tmp/orca-serve.log
```

### Container restarts in a loop

```bash
docker compose logs --tail=100 orca
```

Exit status 3 means a profile lock (above). Any other immediate exit usually
means a bad `ORCA_PAIRING_ADDRESS` or `ORCA_PORT` — both are validated at startup
and fail fast with a message naming the variable.

---

## Credits

- [Orca](https://github.com/stablyai/orca) by Stably — the application this
  repository packages. MIT licensed.
- [Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
  — the upstream guide this image follows, and the source for the dependency
  list, the `--appimage-extract` guidance, and the readiness contract.
- [Remote Orca Servers](https://www.onorca.dev/docs/remote-servers) — upstream
  documentation for `orca serve` and pairing.
- [AppImage documentation](https://docs.appimage.org/user-guide/troubleshooting/fuse.html)
  — extract-and-run, and why FUSE in containers is a bad idea.
- [Playwright](https://playwright.dev/docs/docker) and
  [Puppeteer](https://pptr.dev/guides/docker) Docker guidance — the reference for
  Chromium sandbox behaviour in containers.

## License

[MIT](LICENSE). This repository packages Orca but is not affiliated with or
endorsed by Stably.
