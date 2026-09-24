# A complete example

A full deployment for a self-hosted server: absolute host paths instead of named
volumes, the agent binaries and configuration shared from the host, and Orca's own
state kept separate from them.

Placeholders you need to replace: `/srv/orca` (where Orca's state lives),
`/home/deploy` (the host account that owns the agents), and `PUID`/`PGID`.

---

## The compose

```yaml
services:
  orca:
    image: ghcr.io/ivan-cavero/orca-headless:latest
    container_name: orca
    restart: unless-stopped
    init: true
    stop_grace_period: 30s

    # Must match the owner of the mounts below. Check with `id -u` / `id -g` on
    # the host: it is not always 1000.
    user: "${PUID:-1000}:${PGID:-1000}"

    ports:
      - "${ORCA_HOST_PORT:-6768}:${ORCA_PORT:-6768}"

    environment:
      # HOME is the host account's home path, so every agent path inside the
      # container matches the host exactly. See "Why it is shaped this way".
      HOME: /home/deploy

      ORCA_PORT: "${ORCA_PORT:-6768}"
      ORCA_HOST_PORT: "${ORCA_HOST_PORT:-6768}"
      ORCA_PAIRING_ADDRESS: "${ORCA_PAIRING_ADDRESS:?set this to the address your clients dial}"
      ORCA_JSON: "true"
      ORCA_NO_SANDBOX: "true"
      ORCA_EXTRA_ARGS: "${ORCA_EXTRA_ARGS:-}"

      # The agent paths are the HOST paths, because that is where they are mounted.
      PATH: "/home/deploy/.bun/bin:/home/deploy/.local/bin:/opt/orca/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    volumes:
      # Orca's own state: projects, worktrees, pairing keys, skills.
      # The container sees this as /home/deploy, which is why Orca writes to
      # /srv/orca/home/.config/orca and /srv/orca/home/orca/workspaces on the host.
      - /srv/orca/home:/home/deploy

      # Agent binaries and configuration, overlaid from the real host home at the
      # same paths. Read-only: the container has no business modifying them.
      # Leave out any directory the host does not have.
      - /home/deploy/.bun:/home/deploy/.bun:ro
      - /home/deploy/.local:/home/deploy/.local:ro
      - /home/deploy/.agents:/home/deploy/.agents
      - /home/deploy/.config/opencode:/home/deploy/.config/opencode
      # Note: mounting a directory that does not exist on the host makes Docker
      # create it as a root-owned empty directory. Leave out anything you do not
      # have, and keep it out of PATH too.

    healthcheck:
      test: ["CMD", "/usr/local/bin/orca-healthcheck"]
      interval: 15s
      timeout: 10s
      start_period: 90s
      retries: 3

    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
```

There is no top-level `volumes:` block: every mount is a host path.

## Preparing the host

```bash
# Orca's state directory, owned by the account the container runs as.
sudo mkdir -p /srv/orca/home
sudo chown -R "$(id -u):$(id -g)" /srv/orca/home

# Which uid do the agents belong to? It is not always 1000, and this is the
# number that has to go in PUID/PGID.
id -u; id -g
stat -c '%u:%g %n' ~/.bun ~/.local ~/.agents ~/.config/opencode 2>/dev/null
```

**`PUID`/`PGID` must match the owner of the agent directories, not just the state
directory.** The two are usually the same account, but if they are not, the container
can read the agent directories and not write them: the mounts look fine, the agents
start, and anything that writes — `orca skills install`, an agent saving a session —
fails with a permission error inside a directory that appears to belong to you.

Then set `PUID` and `PGID` in `.env` to those numbers, and
`ORCA_PAIRING_ADDRESS` to the address your clients dial.

## Where everything ends up

| You see, inside the container | It is, on the host |
| --- | --- |
| `/home/deploy/.config/orca` | `/srv/orca/home/.config/orca` |
| `/home/deploy/orca/workspaces/<repo>/<wt>` | `/srv/orca/home/orca/workspaces/<repo>/<wt>` |
| `/home/deploy/projects/<repo>` | `/srv/orca/home/projects/<repo>` |
| `/home/deploy/.agents/skills` | `/home/deploy/.agents/skills` — the real host home |
| `/home/deploy/.config/opencode` | `/home/deploy/.config/opencode` — the real host home |

Orca's state is isolated under `/srv/orca`; the agent tooling is the host's, unchanged.
The two live in the same path space, which is what makes the agent symlinks and
configuration resolution work without special cases.

**Repositories are imported from `/home/deploy/projects/...` inside the container**,
which is `/srv/orca/home/projects/...` on the host. Orca records absolute paths, so
import them through that path and keep it stable.

---

## Why it is shaped this way

Three rules, each of which cost real debugging time.

### Binaries must be mounted at their own path

Agent installers leave **absolute symlinks** to versioned directories:

```
/home/deploy/.local/bin/claude -> /home/deploy/.local/share/claude/versions/2.1.217
```

Mount that directory at a different path and the symlink still names the host path,
which does not exist inside the container. It dangles, `command -v claude` finds
nothing, Orca reports no agents — and it looks like a libc problem, which it is not.

### Configuration must be where the agent looks for it

Agents resolve their configuration under `$HOME`. That is why `HOME` is set to the
host account's home path: then the mounted `.config/opencode` is exactly where
opencode looks, with no second path to keep in sync.

### Mounting a deep path needs its parents to exist

Mounting the host's opencode session store at `/home/orca/.local/share/opencode`
creates `/home/orca/.local` as a **root-owned mount point**, and the unprivileged user
then cannot create anything beside it:

```
EACCES: permission denied, mkdir '/home/orca/.local/state'
```

The image now creates `$HOME/.local`, `.local/bin`, `.local/share`, `.local/state` and
`.cache` with the right ownership, so a deep mount under the home does not break its
parent. Verified: with the session store mounted that way, `opencode --version`
reports its version instead of failing.

### Only mount what exists

Docker creates a missing bind source as a **root-owned empty directory**. A mount for
an agent you do not have leaves a stray root-owned directory in your home and a
`PATH` entry that resolves to nothing. Check first:

```bash
for d in .bun .local .agents .config/opencode; do
  [ -d "/home/deploy/$d" ] && echo "present: $d" || echo "MISSING: $d"
done
```

---

## Variant: the whole home, three variables

If you do not need Orca's state kept apart from your home, the shipped
`docker-compose.yml` already does what this file does — set three variables and skip
the rest:

```bash
# .env
ORCA_HOME_DIR=/home/deploy
PUID=1001
PGID=1001
```

Everything under `/home/deploy` is mounted at its own path, `HOME` becomes
`/home/deploy`, and the entrypoint puts `$HOME/.local/bin`, `$HOME/.bun/bin` and
`$HOME/.grok/bin` on `PATH`. Agents, their configuration and your skills all work
with no per-directory mounts.

The tradeoff is that Orca's state lands in your real home
(`/home/deploy/.config/orca`), mixed with everything else, and that a hand-run
`orca serve` on the same host has to be stopped first or the container exits 3 on the
profile lock.

## Variant: separate homes

If you would rather keep Orca's home separate from the host account's, drop the
`HOME` override and mount the agent directories where the container expects them:

```yaml
    environment:
      PATH: "/srv/agents/.bun/bin:/srv/agents/.local/bin:/opt/orca/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    volumes:
      - /srv/orca/home:/home/orca                      # Orca's state
      - /srv/agents/.bun:/srv/agents/.bun:ro           # binaries: at their own path
      - /srv/agents/.local:/srv/agents/.local:ro
      - /srv/agents/.agents:/home/orca/.agents         # config: under the container HOME
      - /srv/agents/.config/opencode:/home/orca/.config/opencode
```

Note the asymmetry: **binaries keep their own path, configuration moves to the
container's home.** That is the rule from above, and it is easy to get backwards.

This variant is more explicit about what comes from where. The first one is shorter
and has fewer paths to keep in sync.

---

## Before you deploy

- [ ] `PUID`/`PGID` match `id -u` / `id -g` on the host, and both `/srv/orca/home`
      **and the agent directories** are owned by them.
- [ ] Every bind source exists on the host.
- [ ] `ORCA_PAIRING_ADDRESS` is an address your clients can actually reach, and it is
      **not** `127.0.0.1`.
- [ ] The port is not exposed to the public internet in clear text. See below.

## About exposing the port

Orca's runtime is a control plane for terminals and agents. Upstream is explicit:

> Do not forward the Orca port directly to the public internet. Prefer Tailscale,
> WireGuard, a trusted LAN, SSH forwarding, or an authenticated tunnel.

The pairing code protects access, but it is one secret standing between the internet
and a shell on your server, with no transport encryption.

**Tailscale** is the path upstream recommends and the least work:

1. Install Tailscale on the server and sign in. It gets a `100.x.y.z` address.
2. Install Tailscale on each client — desktop, laptop, phone — on the same tailnet.
3. Set `ORCA_PAIRING_ADDRESS=100.x.y.z`.
4. Close the published port in your firewall.

Clients keep working, the port stops being reachable from the internet, and the
address is stable. WireGuard or an authenticated tunnel with WebSocket support work
too; if you terminate TLS at a proxy, advertise the `https://` URL instead — Orca
normalises it to `wss://`.
