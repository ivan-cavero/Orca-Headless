# Orca Headless Docker

[![Build and publish image](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Image: ghcr.io](https://img.shields.io/badge/ghcr.io-orca--headless-blue?logo=docker&logoColor=white)](https://github.com/ivan-cavero/orca-headless/pkgs/container/orca-headless)
[![Orca](https://img.shields.io/badge/orca-v1.4.206-black)](https://github.com/stablyai/orca/releases)

Run [Orca](https://www.onorca.dev) — the agent development environment — on a Linux
server with **no desktop session**: a VPS, a build box, a VM, a home server. Then
connect to it from the Orca desktop app, the browser, or your phone.

Orca ships a `serve` mode that runs the full runtime without opening a window, but
getting it there by hand means installing a specific set of Electron libraries,
working around a missing FUSE device, arranging a virtual X display, keeping the
thing alive across reboots, and getting the pairing address right so a client can
actually reach it. This repository packages all of that into one image and a
compose file:

```bash
cp .env.example .env      # set ORCA_PAIRING_ADDRESS
mkdir -p projects
docker compose up -d
```

What you get:

- **Headless by construction.** No FUSE, no `--privileged`, no `xvfb-run` wrapper,
  no desktop packages. Orca manages its own virtual display.
- **Runs unprivileged.** A dedicated non-root user, with `cap_drop: ALL` and
  `no-new-privileges` applied.
- **Persistent.** Projects, worktrees, terminal history and paired-device keys
  survive `docker compose down`, image upgrades, and even a `SIGKILL`.
- **Reachable.** A verified pairing flow for the desktop client, the web client
  and the mobile app — with the port arithmetic handled for you.
- **Verifiable.** The healthcheck parses Orca's own versioned readiness contract
  instead of just poking the TCP port.

> Remote Orca Servers are **beta** upstream. Keep the listener on a private
> network path you control — Tailscale, WireGuard, a trusted LAN, or an
> authenticated tunnel. Do not expose it to the public internet.

---

## Contents

- [Quick start](#quick-start)
- [Getting the pairing link](#getting-the-pairing-link)
- [Reading the console](#reading-the-console)
- [Choose a deployment model](#choose-a-deployment-model)
- [Connecting a client](#connecting-a-client)
- [Paths](#paths)
- [Running like a native install](#running-like-a-native-install)
- [Configuration](#configuration)
- [Redeploying](#redeploying)
- [Security](#security)
- [Running agent CLIs](#running-agent-clis)
- [Building the image yourself](#building-the-image-yourself)
- [Image size](#image-size)
- [What was verified](#what-was-verified)
- [Troubleshooting](#troubleshooting)
- [Credits](#credits)

---

## Quick start

Requirements: Docker Engine 20.10+ with the Compose plugin, or Podman 4+. A 64-bit
Linux host (`amd64` or `arm64`). No GPU, no display, no FUSE.

```bash
git clone https://github.com/ivan-cavero/orca-headless.git
cd orca-headless

cp .env.example .env
$EDITOR .env                     # at minimum: ORCA_PAIRING_ADDRESS

docker compose up -d
```

No host directory is needed. State, worktree checkouts and the projects folder all
default to named volumes, so the command above is the whole setup.

Then get your pairing link:

```bash
docker compose exec orca orca-pairing-url
```

### With rootless Podman

Add the rootless overlay — **always**, with either compose file. A rootless runtime
maps your host UID to container UID 0, so any bind-mounted directory looks
root-owned inside the container and the unprivileged `orca` user cannot write to it:

```bash
podman-compose -f docker-compose.yml -f docker-compose.rootless.yml up -d
```

On an SELinux host (Fedora, RHEL, CentOS) also set `ORCA_SELINUX_LABEL=:z` in
`.env` when you mount a host directory, or the label blocks writes even when Unix
permissions look correct.

The entrypoint warns when it detects either problem, naming the directory it could
not write to, so a misconfiguration is loud rather than silent.

### Check it came up

```bash
docker compose ps
# NAME   STATUS
# orca   Up 2 minutes (healthy)
```

---

## Getting the pairing link

Orca mints the pairing link at startup and writes it to its readiness output.
**There is no CLI command to mint one against a running runtime** — the log is the
only source, so this image ships a helper that reads it:

```bash
docker compose exec orca orca-pairing-url
```

```
Pairing scope : runtime
Bound         : ws://0.0.0.0:6768
Advertised    : ws://10.0.0.5:6768

Pairing URL (paste into Orca: Settings -> Remote Orca Servers -> Add Server):

  orca://pair?code=eyJ2IjoyLCJlbmRwb2ludCI6IndzOi8vMTAuMC4wLjU6Njc2OCIs...

Browser URL (open it directly, the pairing code is embedded):

  http://10.0.0.5:6768/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D...
```

Or read it straight from the logs, which is the same data:

```bash
docker compose logs orca | grep -o 'orca://pair?code=[^"]*' | tail -1
```

The link is **stable**. It is derived from device credentials stored in the state
directory, so it is byte-identical across `docker compose restart` and across a
full `down` + `up`. A client that already paired stays paired through a redeploy,
and you can re-read the same link any time.

It changes only when the state is destroyed — `docker compose down -v` — or when
you revoke the grant. After either, clients must pair again.

If you need a fresh link without losing state, revoke the old grant from the
client's **Shared Server Access** list and restart the container.

---

## Reading the console

A first run looks alarming. Here is every line, and which ones matter.

```
[entrypoint] starting Orca server              <- informational, from this image
[entrypoint]   listen port      : 6768
[entrypoint]   published port   : 6768
[entrypoint]   pairing address  : 10.0.0.5:6768
[entrypoint]   expected noise   : ...          <- tells you the next lines are fine

ERROR:dbus/bus.cc:406] Failed to connect to the bus: ...   <- NOISE, harmless
ERROR:dbus/bus.cc:406] Failed to connect to the bus: ...   <- NOISE, harmless
[secrets] The OS keyring is unavailable, so secrets are stored unencrypted.
                                                           <- REAL, read Security
ERROR:dbus/object_proxy.cc:572] Failed to call method: ... <- NOISE, harmless
[codex-trust-grant] falling back to self-computed trust ... Error: spawn codex ENOENT
                                                           <- REAL, no Codex installed
[serve] orca CLI install: installed (/home/orca/.local/bin/orca-ide)
[serve] bare orca dispatcher installed: ...
{"type":"orca_server_ready","schemaVersion":1,...}          <- THIS IS THE ONE
```

| Line | Meaning |
| --- | --- |
| `Failed to connect to the bus` / `org.freedesktop.DBus` | **Harmless.** There is no session D-Bus in the container. Orca does not need one to serve. |
| `[secrets] The OS keyring is unavailable` | **Real.** No keyring, so secrets are stored unencrypted in the state directory. See [Security](#security). |
| `spawn codex ENOENT` / `spawn claude` | **Real but non-fatal.** The agent CLI is not installed, so that agent cannot run. Orca still serves. See [Running agent CLIs](#running-agent-clis). |
| `[serve] orca CLI install: installed` | **Informational.** The CLI is now on `PATH` inside the container. |
| `Another Orca instance is already running` | **Fatal, exit 3.** A profile lock. See [Troubleshooting](#another-orca-instance-is-already-running-for-this-userdata-profile). |
| `{"type":"orca_server_ready",...}` | **The readiness contract.** Orca is serving. This is what the healthcheck waits for. |

The line that decides whether the container is usable is the last one. Everything
before it is either noise or a warning you can act on later.

To see only what matters:

```bash
docker compose logs orca | grep -E 'orca_server_ready|\[entrypoint\]|secrets|ENOENT'
```

---

## Choose a deployment model

There are two, and the difference matters more than it looks. Orca stores
**absolute paths** in its state and creates worktree checkouts under
`$HOME/orca/workspaces` — a path derived from `HOME`. So where you point `HOME`
decides whether the host and the container agree about where your files are.

| | `docker-compose.yml` | `docker-compose.hostpaths.yml` |
| --- | --- | --- |
| State, worktrees | named Docker volumes | a real host directory |
| Worktrees visible on the host | no | yes |
| Host `git worktree list` on an Orca-created worktree | reports `prunable` | valid |
| Setup effort | none | one `mkdir` + one variable |
| Best for | trying it out, keeping the host clean | a VPS you also SSH into |

**Use `docker-compose.yml` if** you want the simplest thing that works, and you
will do all your git work through Orca.

**Use `docker-compose.hostpaths.yml` if** you also work on the machine directly.
It points `HOME` at a host directory and mounts it at its own absolute path, so
the container path and the host path are identical:

```
/srv/orca/home/.config/orca                     Orca state
/srv/orca/home/orca/workspaces/<repo>/<wt>      worktree checkouts
/srv/orca/home/projects/<repo>                  your repositories
```

```bash
sudo mkdir -p /srv/orca/home/projects
sudo chown -R "$(id -u):$(id -g)" /srv/orca/home
# then in .env:  ORCA_HOME_DIR=/srv/orca/home

docker compose -f docker-compose.hostpaths.yml up -d
```

`ORCA_HOME_DIR` is required — the file refuses to start without it rather than
silently mounting a relative path. Use this file *instead of* `docker-compose.yml`,
not together with it.

---

## Connecting a client

Get the link first — see [Getting the pairing link](#getting-the-pairing-link).

- **Desktop app** — **Settings → Remote Orca Servers → Add Server**, paste the
  pairing URL.
- **Browser** — open the `Browser URL` instead; the pairing code is already
  embedded in the fragment, so it connects without any copy-paste.
- **Mobile** — see below. It needs a different kind of link.

### Mobile pairing is a separate mode

`--mobile-pairing` does not add a second link — it **replaces** the runtime link
with a mobile-scoped one. Upstream is explicit: it prints a mobile-scoped QR/link
*"instead of the default runtime-environment pairing link"*.

```bash
# in .env
ORCA_EXTRA_ARGS=--mobile-pairing
ORCA_JSON=false          # required for the scannable QR; JSON mode reports qr:null
```

Restart, then scan the QR from the logs with the Orca Mobile app's **Pair** flow,
or copy the link that `orca-pairing-url` prints.

Two consequences worth knowing, both verified:

- A **desktop client cannot use a mobile-scoped code.** `orca-ide environment add`
  accepts it but the connection fails (`runtimeId: null`).
- So you get **one or the other per run.** Leave `ORCA_EXTRA_ARGS` empty for
  desktop and browser clients; set it when you are pairing a phone. The
  `orca-pairing-url` helper tells you which kind of link you are looking at.

`--no-pairing` disables pairing entirely if the runtime should not be reachable at
all.

### The one thing that breaks connections

The client dials `ORCA_PAIRING_ADDRESS`. It must be an address the client can
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
2. **A firewall.** Open `ORCA_HOST_PORT` (default `6768`) for the client's source.
3. **A reverse proxy without WebSocket upgrade.** The runtime speaks WebSocket,
   not HTTP; the proxy must forward the `Upgrade`/`Connection` headers and route
   the advertised path. Advertise `https://…` when TLS terminates at the proxy —
   Orca normalises it to `wss://`.

### Ports, and why the entrypoint rewrites your address

Orca builds the advertised endpoint from the address you give it plus **the port it
bound inside the container**. That is the container's port, not the port you
published. So publishing `-p 16774:6768` and advertising a bare `10.0.0.5` hands
clients `ws://10.0.0.5:6768` — nothing is listening there.

The entrypoint prevents this: it appends `ORCA_HOST_PORT` whenever the pairing
address is a bare host, and leaves addresses alone when they already carry a port
or are a full URL. Change `ORCA_HOST_PORT` in `.env` and the mapping, the advertised
endpoint and the pairing code stay consistent.

| `ORCA_PAIRING_ADDRESS` | `ORCA_HOST_PORT` | advertised |
| --- | --- | --- |
| `10.0.0.5` | `16774` | `ws://10.0.0.5:16774` |
| `10.0.0.5:443` | `16774` | `ws://10.0.0.5:443` (explicit wins) |
| `https://orca.example.com/runtime` | any | `wss://orca.example.com/runtime` |
| `[fd00::1]` | `16774` | `ws://[fd00::1]:16774` |

### Verify a pairing actually works

The image ships the `orca-ide` CLI, so you can prove the connection from the server
without a GUI client. `orca-ide status --environment <name>` queries the *remote*
runtime over the paired WebSocket:

```bash
docker compose exec orca sh -c '
  orca-ide environment add --name self --pairing-code "orca://pair?code=..."
  orca-ide status --environment self --json | head -30'
```

A healthy answer carries `"runtime": {"state": "ready", "connectionState":
"connected"}` and a `runtimeId` that is **not** `"local"`. That is the same
handshake the desktop and mobile clients perform.

The pairing URL contains a device credential and E2EE material. Treat it like a
password, and revoke grants you no longer need from **Shared Server Access** on the
server side.

---

## Paths

Three paths matter, and each has one job.

| Container path | Job | Must be writable | Must persist |
| --- | --- | --- | --- |
| `/home/orca/.config` | Orca's state: projects, worktree metadata, terminal history, orchestration state, paired-device keys. Orca uses **both** `~/.config/orca` and `~/.config/Orca`. | yes | yes |
| `/home/orca/orca/workspaces` | The actual worktree checkouts. **Orca creates these here, not inside the repo you import.** | yes | yes |
| `/home/orca/projects` (or your own path) | The repositories you import into Orca. Defaults to a named volume, so it works with no host folder; point `ORCA_PROJECTS` at a host directory to use real files. | yes | yes |

Two mistakes are easy to make and expensive:

- **Not persisting `/home/orca/orca`.** The metadata in `.config` survives a
  recreate but the checkouts do not, so Orca lists worktrees whose files are gone.
  Both compose files mount it; if you write your own, do not forget it.
- **Mounting the same named volume at both `.config/orca` and `.config/Orca`.**
  Docker presents the same directory contents at both paths, which is not what
  Orca expects. Mount the parent.

### Importing a project

Orca identifies a project by its **git remote**, not by a folder name. A folder
with no `origin` remote cannot be imported — `project setup-existing-folder` fails
with *"Imported folder does not match the selected project identity."* The project
id is derived from the remote, for example `github:owner/repo`.

For remote runtimes the path you pass must be an **absolute path inside the
container**:

```bash
docker compose exec orca orca-ide project setup-existing-folder \
  --project github:owner/repo --host local --path /home/orca/projects/repo --kind git --json
```

This is where the deployment model shows up. With `docker-compose.yml` you type
`/home/orca/projects/...`; with `docker-compose.hostpaths.yml` you type the same
path you would use on the host. Orca records whatever you type, so pick a stable
container path and keep it.

`repo add` is a shorter equivalent when you only need the folder registered:

```bash
docker compose exec orca orca-ide repo add --path /home/orca/projects/repo --json
```

### Backing up

```bash
# named-volume model
docker run --rm -v orca-headless_orca-config:/data -v "$PWD":/backup \
  alpine tar czf /backup/orca-state-$(date +%F).tgz -C /data .

# host-paths model
sudo tar czf orca-state-$(date +%F).tgz -C /srv/orca/home .config orca
```

---

## Running like a native install

The short answer: **yes, with the host-path deployment the container sees the same
layout a native install would, and the only thing that matters is the UID/GID, not
the user name.**

A native Orca install on a Linux server puts everything under the user's home:

```
/home/dev/.config/orca            state
/home/dev/.config/Orca            state (Orca uses both names)
/home/dev/orca/workspaces/...     worktree checkouts
```

Point the host-path deployment at that same home and it is identical:

```yaml
# .env
ORCA_HOME_DIR=/home/dev
PUID=1000          # the uid of `dev` on the host
PGID=1000          # the gid of `dev` on the host
```

Inside the container `HOME` is `/home/dev`, Orca writes to `/home/dev/.config/orca`
and creates worktrees under `/home/dev/orca/workspaces`, exactly as it would if you
had installed it with `curl | bash`. Anything you can do from the host shell you can
do to the same files, and vice versa.

### About the user name

The container's internal account is called `orca` by default, and that name is
**cosmetic**. What the filesystem actually checks is the numeric UID/GID:

| | Why it matters |
| --- | --- |
| **PUID / PGID** | Decides who owns the files. Must match the host user that owns `ORCA_HOME_DIR`, or the container cannot write. |
| **`ORCA_USER`** | Just the label in `/etc/passwd`. Changing it does not change file ownership. |
| **`HOME`** | Decides *where* Orca puts state and worktrees. This is the one that must match the host path. |

So if your server user is `dev` with uid 1000, you do **not** need to rename
anything: `PUID=1000` and `ORCA_HOME_DIR=/home/dev` already give you a deployment
that behaves natively. The `orca` label never appears in a path you care about.

If you want cosmetic parity too — the account genuinely named `dev`, with
`/home/dev` as its passwd home — build the image with:

```bash
docker build --build-arg ORCA_USER=dev --build-arg PUID=1000 --build-arg PGID=1000 -t orca-headless:dev .
```

That is the only way to change the name, because a non-root process cannot add
itself to `/etc/passwd`. It is not required for anything to work.

---

## Configuration

Every variable is optional except `ORCA_HOME_DIR` in the host-paths model. Copy
`.env.example` to `.env` and edit.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ORCA_PAIRING_ADDRESS` | `127.0.0.1` | **Set this.** Address clients dial. Hostname, IP, Tailscale address, or a full `https://` reverse-proxy URL. Wildcards are rejected at startup. |
| `ORCA_PORT` | `6768` | Port Orca listens on inside the container. |
| `ORCA_HOST_PORT` | `6768` | Port published on the host. Keep the `ports:` mapping in sync; the entrypoint uses this to build the advertised endpoint. |
| `ORCA_HOME_DIR` | *(required in hostpaths)* | Absolute host path mounted at its own path and used as `HOME`. |
| `ORCA_IMAGE` | `ghcr.io/ivan-cavero/orca-headless:latest` | Image to run. Change it if you forked or build locally. |
| `PUID` / `PGID` | `1000` / `1000` | UID/GID the container runs as. **Build-time** arguments; see [Changing PUID/PGID](#changing-puidpgid). |
| `ORCA_PROJECTS` | `orca-projects` | Where your repositories live: a named volume by default, or a host directory (`./projects`, `/srv/repos`). |
| `ORCA_SELINUX_LABEL` | *(empty)* | `:z` on SELinux hosts (Fedora/RHEL/CentOS). Empty elsewhere. |
| `ORCA_JSON` | `true` | `true` emits the versioned single-line JSON contract; `false` emits the human-readable `Orca server ready` block. |
| `ORCA_NO_SANDBOX` | `true` | Adds Chromium's `--no-sandbox`. Read [Security](#security) before changing. |
| `ORCA_EXTRA_ARGS` | *(empty)* | Extra flags appended to `orca serve`, e.g. `--mobile-pairing`. |
| `ORCA_VERSION` | `v1.4.206` | Orca release baked in. Only read when building locally. |

Inside the container these are set as `ENV` as well, so `docker compose exec orca
sh` sees them.

---

## Redeploying

`orca serve` never updates itself — upstream is explicit that headless mode wires
up no auto-updater, and the runtime reports
`"remoteUpdateSupport": {"automatic": false, "reason": "updater-unavailable"}`.
Upgrading is always a deliberate step: replace the image, restart.

What each command actually does to your image, your container and your data.

| Command | Image | Container | State, worktrees, projects | Pairing |
| --- | --- | --- | --- | --- |
| `docker compose restart` | unchanged | same container | untouched | unchanged |
| `docker compose up -d` | unchanged¹ | recreated only if the compose file changed | untouched | unchanged |
| `docker compose pull && docker compose up -d` | **updated** | recreated | untouched | unchanged |
| `docker compose down && docker compose up -d` | unchanged | recreated | untouched | unchanged |
| `docker compose down -v` | unchanged | recreated | **DESTROYED** | **must re-pair** |

¹ `docker compose up -d` does **not** pull. If the tag is already present locally,
nothing is downloaded and nothing changes. That is why restarting keeps you on the
same version — updating is always an explicit `pull`, or a `--build`.

So, to answer the two questions directly:

- **Restarting keeps everything, including the version.** Nothing is lost, no client
  re-pairs, no worktree moves.
- **Redeploying after a `pull` upgrades Orca and still keeps everything.** The
  volumes outlive the container, so state, worktrees and projects are untouched and
  paired clients reconnect without re-pairing.

### Is persistence optional?

No — it is what the compose files are for. But *where* it persists is your choice:

- **Named volumes** (default). Docker-managed, invisible on the host, survive
  `down`, `up`, `pull` and image rebuilds. Only `down -v` removes them.
- **Host directories** (`ORCA_PROJECTS=/srv/repos`, or the whole `hostpaths`
  deployment). Real files you can inspect and back up with normal tools.

Either way, `down -v` is the destructive command. It is the only routine operation
that costs you Orca's configuration, the worktrees, and every paired client.

### Updating to a newer Orca

```bash
docker compose pull && docker compose up -d          # track :latest
```

To pin instead, build locally at the version you want — the tag is what decides:

```bash
ORCA_VERSION=v1.4.210 docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

`docker compose up -d --build` alone reuses the `ORCA_VERSION` from `.env`, so it
rebuilds the same version rather than fetching a newer one.

New builds migrate older state on load, so a forward upgrade needs no manual data
step.

### What does not survive

**Live processes.** A restart kills every terminal and agent in the container.
Conversations may be resumable, but the running process and any in-flight command
are gone. Orca's own upgrade guidance for systemd deployments is the same: do a
terminal census and finish work before restarting.

**Nothing else**, as long as you did not pass `-v`.

### Rolling back

A newer build may rewrite `orca-data.json` in a newer schema, and an older build can
then discard fields it does not recognise. Roll back the **state and the image
together** — restoring the image alone is not safe:

```bash
docker compose down
# restore the state volume (or directory) from a backup taken before the upgrade
ORCA_IMAGE=ghcr.io/ivan-cavero/orca-headless:1.4.200 docker compose up -d
```

---

## Security

### Non-root, no capabilities

The container runs as an unprivileged user (`orca`, UID/GID 1000 by default), never
as root, and the compose files additionally apply:

```yaml
security_opt:
  - no-new-privileges:true
cap_drop:
  - ALL
```

Both were verified compatible with the default configuration. Combined with
Docker's default seccomp profile, that is a meaningfully smaller blast radius than
running as root.

### About `--no-sandbox`

`ORCA_NO_SANDBOX=true` is the default because it is the **only configuration that
works in an unmodified container**, and the reason is structural rather than
cosmetic:

- Chromium's SUID sandbox helper (`chrome-sandbox`, root-owned, mode 4755) needs
  `CAP_SYS_ADMIN` to create its PID and network namespaces. Docker's default
  capability bounding set does not include `CAP_SYS_ADMIN`, and the bounding set is
  not regained through setuid. The helper therefore fails with `Failed to move to
  new namespace`.
- The user-namespace sandbox is also unavailable by default: Docker's seccomp
  profile gates `unshare`/`setns` behind `CAP_SYS_ADMIN`, and on Ubuntu 23.10+
  hosts the kernel's AppArmor unprivileged-userns restriction blocks it too.
- `no-new-privileges` disables setuid elevation outright, and `cap_drop: ALL`
  empties the bounding set — so both hardening options above are mutually exclusive
  with a working sandbox.

Upstream says the same thing from the other direction: running the AppImage as root
requires `--no-sandbox`, and a dedicated unprivileged service user is preferred.
This image drops the Chromium sandbox but keeps the process unprivileged, which
still bounds what a compromised renderer can touch.

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
path Playwright and Puppeteer document for non-root containers; decide
deliberately.

### Secrets are stored unencrypted

Orca logs this on every start in a container:

```
[secrets] The OS keyring is unavailable, so secrets are stored unencrypted.
```

There is no unlocked D-Bus session keyring in a headless container, so Orca falls
back to storing secrets in the state directory in plaintext. Anyone who can read
that volume or directory can read them. Restrict access to it, and prefer
environment-based credentials for the agent CLIs where the tool supports it.

### Do not expose the port publicly

The runtime is a WebSocket control plane for terminals and agents. Upstream
recommends Tailscale, WireGuard, a trusted LAN, SSH forwarding, or an authenticated
tunnel. Port-forwarding `6768` to the internet is not a supported configuration.

---

## Running agent CLIs

The image contains Orca and its dependencies, **not** the coding agents. Orca shells
out to `codex`, `claude`, `opencode` and friends, so a missing binary shows up like
this on startup:

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
GNOME Orca screen reader. It resolves at `/opt/orca/bin/orca-ide` regardless of
`HOME`. `orca serve` also writes a bare `orca` dispatcher into `$HOME/.local/bin`
for the service user's own shell.

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

PUID and PGID are **build-time** values, so the container's `user:` must match the
image's build arguments. If you change one and not the other, the state directory is
owned by a different UID and Orca cannot persist anything — the entrypoint warns you.

```bash
PUID=1500 PGID=1500 docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

Fix the ownership of an existing volume or host directory:

```bash
docker compose down
docker run --rm -v orca-headless_orca-config:/data alpine chown -R 1500:1500 /data
# host-paths model instead:
sudo chown -R 1500:1500 /srv/orca/home
docker compose up -d
```

---

## Image size

The published image is roughly **1.1 GB** on disk. That is normal for an
Electron/Chromium application, and most of it is not this Dockerfile's doing:

| Layer | Size | What it is |
| --- | --- | --- |
| Extracted Orca app | ~568 MB | Chromium runtime + Orca's application resources |
| System libraries | ~470 MB | The Electron dependency set. `libgbm1` alone pulls `mesa-libgallium` → `libllvm20` (~178 MB), which cannot be dropped without breaking Electron. `git` pulls ~55 MB of Perl. |
| Ubuntu base | ~81 MB | `ubuntu:24.04` |

What this repository *did* optimise: a multi-stage build keeps the 192 MB AppImage
out of the final image entirely, `--no-install-recommends` is used throughout,
`apt-get update` and `install` share a single layer, and the apt lists are removed
in that same layer. Aggressive trimming (dropping unused Electron locales, for
example) was deliberately **not** applied — it saves about 4% and risks breaking
localisation for no real benefit.

---

## What was verified

Honest accounting. The following were executed against the built image on
**Podman 5.8.7 / Fedora 44, x86_64**, not merely reasoned about:

| Check | Result |
| --- | --- |
| Image builds from a clean base | ✅ |
| Container reaches `healthy` via its own `HEALTHCHECK` | ✅ ~15–20 s after start |
| Orca emits `{"type":"orca_server_ready","schemaVersion":1,…}` | ✅ |
| Human-readable `Orca server ready` block with `ORCA_JSON=false` | ✅ |
| Healthcheck passes in both JSON and text modes | ✅ |
| No FUSE, no `--privileged`, no `xvfb-run` | ✅ Orca starts its own Xvfb |
| Web client served: `GET /web-index.html` → 200 `text/html`, `<title>Orca Web</title>` | ✅ |
| WebSocket upgrade → `101 Switching Protocols` with a valid `Sec-WebSocket-Accept` | ✅ |
| **Pairing end to end between two containers on a shared network** | ✅ `environment add` + `status --environment` returned the remote `runtimeId` with `connectionState: "connected"` |
| Mobile pairing (`--mobile-pairing`) mints a `scope: "mobile"` code | ✅ and prints a scannable QR when `ORCA_JSON=false` |
| A mobile-scoped code is **rejected** by a desktop consumer | ✅ `environment add` accepts it, `status --environment` fails with `runtimeId: null` |
| Pairing link is retrievable from a running container | ✅ `orca-pairing-url` in JSON and text modes, plus the raw log one-liner |
| Pairing link is **stable across `restart` and across `down` + `up`** | ✅ byte-identical; `deviceId` persisted in the volume |
| Pairing link **changes** after `down -v` | ✅ new `deviceId`; clients must re-pair |
| `--project-root` does **not** move the worktree root | ✅ worktrees still land under `$HOME/orca/workspaces` |
| Default deployment needs **no host directory at all** | ✅ three named volumes, zero warnings, healthy |
| `orca-ide` resolves on `PATH` in a running container | ✅ |
| Pairing address → advertised endpoint, 7 cases incl. IPv6 and URLs | ✅ unit-tested |
| Port published as `16774:6768` advertises `:16774`, not `:6768` | ✅ |
| State survives `SIGKILL` followed by restart | ✅ stale `SingletonLock` recovered |
| Graceful `SIGTERM` shutdown | ✅ exit 0, immediate |
| `cap_drop: ALL` + `no-new-privileges` | ✅ still reaches ready |
| Wildcard `ORCA_PAIRING_ADDRESS` and non-numeric ports rejected at startup | ✅ exit 1, message names the variable |
| `docker-compose.yml` and `docker-compose.hostpaths.yml` run end to end | ✅ via `podman-compose` |
| Rootless Podman fixes (`keep-id`, `:z`) | ✅ verified writable |
| Unwritable state / workspaces / projects directory produces a warning | ✅ |

**Not verified here, and worth knowing:**

- **The GHCR publish workflow has never been executed.** GitHub Actions was not
  available in the environment where this repository was assembled. The action
  versions are current as of the pinned majors, and the `smoke-test` job mirrors
  the exact steps verified above — including the worktree-persistence check.
- **`arm64` is built by CI but was not tested on real hardware.** `amd64` is the
  tested target.
- **Docker Engine itself was not used** — Podman was, because that is what the
  environment had. Compose semantics are shared and the compose files avoid
  engine-specific syntax, but a Docker-only difference would be a bug worth
  reporting.
- **No GUI client was run.** The pairing flow was verified with `orca-ide
  environment add` / `status --environment`, which performs the same WebSocket
  handshake the desktop and mobile clients perform, plus an HTTP fetch of the web
  client and a raw WebSocket upgrade. That is strong evidence, not the same thing
  as a human clicking **Add Server**.

---

## Troubleshooting

### I cannot find the pairing link

```bash
docker compose exec orca orca-pairing-url
```

If it says Orca has not reported a pairing link yet, the runtime is still starting —
wait a few seconds. If it keeps saying that, pairing failed; the log carries a stable
reason:

```bash
docker compose logs orca | grep -o '"pairing":{[^}]*}'
```

Stable reasons are `disabled_by_operator` (you passed `--no-pairing`),
`websocket_unavailable`, `device_registry_unavailable`, `e2ee_key_unavailable` and
`invalid_advertised_endpoint`. The last one means `ORCA_PAIRING_ADDRESS` was a
wildcard or otherwise unusable.

### The logs look broken before the server starts

They are not — see [Reading the console](#reading-the-console). D-Bus and keyring
messages are expected on a headless host. The only line that means "it works" is
`orca_server_ready`.

### The client cannot connect

Nine times out of ten it is `ORCA_PAIRING_ADDRESS`. Check what was advertised:

```bash
docker compose logs orca | grep -o '"advertisedEndpoint":"[^"]*"' | tail -1
```

That value is what the client dials. If it says `127.0.0.1`, or an address the
client cannot route to, fix `.env` and `docker compose up -d`. Then confirm the
port is reachable from outside:

```bash
nc -z <server-ip> 6768 && echo open
```

If you changed the published host port, set `ORCA_HOST_PORT` to match — the
entrypoint derives the advertised port from it. See
[Ports](#ports-and-why-the-entrypoint-rewrites-your-address).

### `spawn codex ENOENT` (or `spawn claude`)

The agent CLI is not installed in the container. Orca starts and serves fine, but
that agent cannot be launched. See [Running agent CLIs](#running-agent-clis). This
is the most common first-run surprise.

### Worktrees disappear after `docker compose down`

`/home/orca/orca` is not mounted. Orca creates worktree checkouts under
`$HOME/orca/workspaces`, not inside the repository you import; the metadata lives in
`.config` and survives, so Orca lists worktrees whose files are gone. Both bundled
compose files mount it. See [Paths](#paths).

### `Imported folder does not match the selected project identity`

Orca identifies projects by their git remote. Add an `origin` and use the derived
id (`github:owner/repo`). A folder with no remote cannot be imported.

### `orca-ide: not found`

`orca serve` registers the CLI into `$HOME/.local/bin`. The image also exposes it at
the fixed path `/opt/orca/bin/orca-ide`, which is on `PATH` regardless of `HOME`. If
you overrode `HOME` yourself, use that absolute path or add `$HOME/.local/bin` to
`PATH`.

### `Permission denied` on a mounted directory

Two distinct causes, and the entrypoint names the directory it could not write:

- **Rootless Podman.** Your host UID maps to container UID 0, so the bind mount is
  root-owned inside the container. Add the Podman overlay to *either* compose file:
  `podman-compose -f docker-compose.yml -f docker-compose.rootless.yml up -d`.
- **SELinux host.** Unix permissions look correct but the label blocks writes. Set
  `ORCA_SELINUX_LABEL=:z` in `.env`.

### State does not persist after `down`

Check the container actually got the mounts:

```bash
docker inspect orca --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
```

You should see `/home/orca/.config` and `/home/orca/orca`. If you overrode `user:`
to a UID different from the image's `PUID`, the directories are owned by someone
else and Orca silently fails to write. See
[Changing PUID/PGID](#changing-puidpgid).

### `Another Orca instance is already running for this userData profile`

Orca exits with status **3** when something else already owns the same userData
profile. Find the owner, stop it, and restart. If nothing owns it, the lock is
stale — remove `SingletonLock` and `SingletonSocket` from the state directory:

```bash
docker compose down
docker run --rm -v orca-headless_orca-config:/data alpine \
  rm -f /data/orca/SingletonLock /data/orca/SingletonSocket
docker compose up -d
```

This was tested: a `SIGKILL` leaves those files behind and Orca recovers from them
on the next start. You should not normally need this.

### `dlopen(): error loading libfuse.so.2`

You are running an AppImage directly without FUSE. This image never hits that path
— it extracts the AppImage at build time and runs the extracted tree, so `libfuse2`
is not needed at all. If you see this while running the AppImage yourself, either
install `libfuse2` (Ubuntu 22.04) / `libfuse2t64` (Ubuntu 24.04) or use
`--appimage-extract` once and run `squashfs-root/AppRun`.

### D-Bus errors fill the log

```
ERROR:dbus/bus.cc:406] Failed to connect to the bus: ... /run/dbus/system_bus_socket
```

Expected and harmless on a headless host. Orca does not need a session D-Bus to
serve. The line that matters is `orca_server_ready`.

### `[secrets] The OS keyring is unavailable`

Also expected — see [Security](#security). Secrets are stored unencrypted in the
state directory.

### The container is `unhealthy` but clients work

The healthcheck requires Orca's readiness line in `/tmp/orca-serve.log` **and** an
open listener. Check the log:

```bash
docker compose exec orca cat /tmp/orca-serve.log
```

### Container restarts in a loop

```bash
docker compose logs --tail=100 orca
```

Exit status 3 means a profile lock (above). Any other immediate exit usually means
a bad `ORCA_PAIRING_ADDRESS`, `ORCA_PORT` or `ORCA_HOME_DIR` — all are validated at
startup and fail fast with a message naming the variable.

---

## Credits

- [Orca](https://github.com/stablyai/orca) by Stably — the application this
  repository packages. MIT licensed.
- [Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
  — the upstream guide this image follows, and the source for the dependency list,
  the `--appimage-extract` guidance, the readiness contract, and the state layout.
- [Remote Orca Servers](https://www.onorca.dev/docs/remote-servers) — upstream
  documentation for `orca serve` and pairing.
- [AppImage documentation](https://docs.appimage.org/user-guide/troubleshooting/fuse.html)
  — extract-and-run, and why FUSE in containers is a bad idea.
- [Playwright](https://playwright.dev/docs/docker) and
  [Puppeteer](https://pptr.dev/guides/docker) Docker guidance — the reference for
  Chromium sandbox behaviour in containers.

## License

[MIT](LICENSE). This repository packages Orca but is not affiliated with or endorsed
by Stably.
