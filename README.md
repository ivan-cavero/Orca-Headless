# Orca Headless Docker

[![Build and publish image](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml/badge.svg)](https://github.com/ivan-cavero/orca-headless/actions/workflows/docker-publish.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![Image: ghcr.io](https://img.shields.io/badge/ghcr.io-orca--headless-blue?logo=docker&logoColor=white)](https://github.com/ivan-cavero/orca-headless/pkgs/container/orca-headless)
[![Orca](https://img.shields.io/badge/packages-orca%20v1.4.209-black)](https://github.com/stablyai/orca/releases)

Run [Orca](https://www.onorca.dev) — the agent development environment — on a Linux
server with **no desktop session**: a VPS, a build box, a VM, a home server. Then
connect from the Orca desktop app, the browser, or your phone.

Orca ships a `serve` mode that runs the full runtime without opening a window, but
getting it there by hand means installing a specific set of Electron libraries,
working around a missing FUSE device, arranging a virtual X display, keeping it
alive across reboots, and getting the pairing address right so a client can actually
reach it. This repository packages all of that into **one image and one compose
file**.

```bash
cp .env.example .env      # set ORCA_PAIRING_ADDRESS
docker compose up -d
```

That is the whole setup. No host directory, no `mkdir`, no extra overlay file.

- **Headless by construction** — no FUSE, no `--privileged`, no `xvfb-run`, no
  desktop packages. Orca manages its own virtual display.
- **Unprivileged** — a dedicated non-root user, with `cap_drop: ALL` and
  `no-new-privileges`.
- **Persistent** — state, worktree checkouts and repositories survive restarts,
  redeploys and image upgrades.
- **Reachable** — a verified pairing flow for desktop, browser and mobile, with the
  port arithmetic handled for you.

> Remote Orca Servers are **beta** upstream. Keep the listener on a private network
> path you control — Tailscale, WireGuard, a trusted LAN, or an authenticated
> tunnel. Do not expose it to the public internet.

---

## Quick start

Requirements: Docker Engine 20.10+ with the Compose plugin, or Podman 4+. A 64-bit
Linux host — **`amd64` or `arm64`** (Raspberry Pi 4/5 and other 64-bit ARM boards are
supported; 32-bit ARM is not, because Orca publishes no build for it). No GPU, no
display, no FUSE.

```bash
git clone https://github.com/ivan-cavero/orca-headless.git
cd orca-headless

cp .env.example .env
$EDITOR .env                     # at minimum: ORCA_PAIRING_ADDRESS

docker compose up -d
docker compose ps                # wait for: Up ... (healthy)
```

### Rootless Podman

Same command — the default configuration uses a named volume, and named volumes take
their ownership from the image, so no extra flags are needed:

```bash
podman-compose -f docker-compose.yml up -d
```

The only case that needs help is a **host bind mount** (`ORCA_HOME_DIR`, or mounting
your repositories from the host). A rootless runtime maps your host UID to container
UID 0, so the mount looks root-owned inside and the unprivileged user cannot write to
it. Add one line to the service:

```yaml
services:
  orca:
    userns_mode: keep-id
```

Do **not** add that on rootful Docker — it only accepts `host`. See
[Deployment](docs/deployment.md#rootless-runtimes).

### Dokploy

Paste [`docker-compose.yml`](docker-compose.yml) into a Docker Compose service, set
`ORCA_PAIRING_ADDRESS` in the Environment tab, and deploy. Two things matter there:
leave `ORCA_HOME_DIR` **unset** (Dokploy cleans up absolute host paths between
deployments), and the named volume is what its Volume Backups can snapshot. Full
walkthrough: [Deploying with Dokploy](docs/deployment.md#deploying-with-dokploy).

---

## Get the pairing link

Orca mints the link at startup and writes it to its output. There is no CLI command
to mint one against a running runtime, so this image ships a helper that reads it:

```bash
docker compose exec orca orca-pairing-url
```

```
Pairing scope : runtime
Advertised    : ws://10.0.0.5:6768

Pairing URL (paste into Orca: Settings -> Remote Orca Servers -> Add Server):

  orca://pair?code=eyJ2IjoyLCJlbmRwb2ludCI6IndzOi8vMTAuMC4wLjU6Njc2OCIs...

Browser URL (open it directly, the pairing code is embedded):

  http://10.0.0.5:6768/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D...
```

The link is **stable** — byte-identical across `restart` and across `down` + `up`,
because it is derived from credentials in the persisted state. A redeploy does not
force clients to re-pair. Only `down -v` (or revoking the grant) changes it.

Then:

- **Desktop** — Settings → Remote Orca Servers → Add Server, paste the pairing URL.
- **Browser** — open the Browser URL; the code is already embedded.
- **Mobile** — needs a different link. See
  [Pairing](docs/pairing.md#mobile-pairing-is-a-separate-mode).

**The one thing that breaks connections:** `ORCA_PAIRING_ADDRESS` must be an address
the *client* can reach. `127.0.0.1` points at the client's own loopback, and the
entrypoint warns about it at startup. Full details, including how to prove a pairing
works from the server:
[Pairing and connecting](docs/pairing.md).

---

## What you will actually configure

Three variables cover almost every deployment. Everything else has a working
default.

| Variable | Default | Set it when |
| --- | --- | --- |
| `ORCA_PAIRING_ADDRESS` | `127.0.0.1` | **Always, for any remote client.** The address clients dial: a LAN IP, DNS name, Tailscale address, or a full `https://` reverse-proxy URL. |
| `ORCA_HOME_DIR` | *(empty)* | You want Orca's files to be real files on the host instead of a named volume. |
| `ORCA_EXTRA_ARGS` | *(empty)* | You want `--mobile-pairing` or `--no-pairing`. |

Everything Orca owns lives under `$HOME`, and that is a **single volume** by
default:

```
/home/orca/.config/orca                    state, pairing keys, terminal history
/home/orca/orca/workspaces/<repo>/<wt>     worktree checkouts
/home/orca/projects/<repo>                 the repositories you import
```

Setting `ORCA_HOME_DIR=/srv/orca/home` turns that volume into a bind mount of that
path onto itself, so the container sees exactly the layout a native Orca install
would, at the same absolute paths the host sees — and plain host `git worktree list`
agrees with Orca. Full reference:
[Configuration](docs/configuration.md), [Where everything lives](docs/deployment.md#where-everything-lives).

---

## Documentation

| | |
| --- | --- |
| [Configuration](docs/configuration.md) | Every environment variable, ports, paths, backups |
| [Deployment](docs/deployment.md) | Storage modes, Dokploy, rootless, redeploying, updating, running like a native install |
| [Pairing and connecting](docs/pairing.md) | The pairing link, desktop/browser/mobile clients, network rules, verifying a pairing |
| [Agents and skills](docs/agents-and-skills.md) | Where skills live, how Orca finds agents, and why it cannot run the ones on your host |
| [Security](docs/security.md) | The non-root model, why `--no-sandbox` is the default, stored secrets |
| [Troubleshooting](docs/troubleshooting.md) | Every startup log line explained, and the failures you are likely to hit |
| [Development](docs/development.md) | Building the image, image size, how the pipeline is ordered, the full verification table, what is *not* verified |
| [Contributing](CONTRIBUTING.md) | How to report a bug and how to test a change |
| [Security policy](SECURITY.md) | How to report a vulnerability privately, and the tradeoffs that are already known |
| [Code of conduct](CODE_OF_CONDUCT.md) | Contributor Covenant 2.1 |

**Running agents?** Read [Agents and skills](docs/agents-and-skills.md) first. Orca
launches agents from `PATH` inside its own environment, so it cannot see the ones
installed on your host — they have to be in the image. That page has the verified
recipe.

---

## License and attribution

[MIT](LICENSE). This repository is an independent packaging effort and is **not
affiliated with, sponsored by, or endorsed by** Lovecast Inc., Stably, or the Orca
project.

It packages [Orca](https://github.com/stablyai/orca), which is also MIT licensed:

```
Orca — https://github.com/stablyai/orca
Copyright (c) 2026 Lovecast Inc.
```

Because Orca's AppImage does not ship Orca's own copyright notice, the image build
fetches the exact license text for the pinned release and installs it, so the copy of
Orca inside the image carries its notice as MIT requires. Electron's and Chromium's
licenses travel with Orca's bundle. See [NOTICE](NOTICE) for the full list and where
each file lands inside the image.

Bug reports about Orca itself belong upstream. Bug reports about the container image,
the compose file, or these scripts belong here.
