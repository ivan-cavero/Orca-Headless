# Deployment

## Where everything lives

**One volume. One variable. That is the whole storage model.**

Orca keeps everything under `$HOME`:

```
/home/orca/.config/orca                    state, pairing keys, terminal history
/home/orca/orca/workspaces/<repo>/<wt>     worktree checkouts
/home/orca/projects/<repo>                 the repositories you import
```

By default that `$HOME` is a **named Docker volume** mounted at `/home/orca`, so all
of it persists with zero host setup. `docker compose down` and `up -d` keep
everything; only `down -v` removes it.

If you want those files to be real files on the host instead, set **one** variable:

```bash
# .env
ORCA_HOME_DIR=/srv/orca/home
```

The volume line becomes a bind mount of that directory onto itself, and `HOME`
becomes that path. The container then sees exactly the layout a native Orca install
would, at the same absolute paths the host sees:

```
/srv/orca/home/.config/orca
/srv/orca/home/orca/workspaces/<repo>/<wt>
/srv/orca/home/projects/<repo>
```

Create it first and make it yours:

```bash
sudo mkdir -p /srv/orca/home
sudo chown -R "$(id -u):$(id -g)" /srv/orca/home
```

| | Default (named volume) | `ORCA_HOME_DIR=/srv/orca/home` |
| --- | --- | --- |
| Files visible on the host | no | yes |
| Host `git worktree list` on an Orca worktree | reports `prunable` | valid |
| Back up with normal host tools | no (use `docker run` + tar) | yes |
| Dokploy Volume Backups | yes | no |
| Rootless runtime needs `userns_mode: keep-id` | no | yes |
| Setup effort | none | one `mkdir` |

Pick the named volume unless you specifically want to reach the files from the host
shell.

---

## Deploying with Dokploy

Dokploy runs a rootful Docker daemon, so the defaults work as-is and none of the
rootless advice applies.

1. **Create a Docker Compose service** in Dokploy and paste the contents of
   [`docker-compose.yml`](../docker-compose.yml).
2. **Set the environment** in Dokploy's Environment tab. Dokploy writes those
   variables to a `.env` file next to the compose file, and this compose reads them
   with `${VAR}` references, so they reach the container:

   ```
   ORCA_PAIRING_ADDRESS=<your VPS IP or domain>
   ```

3. **Deploy.**

Three Dokploy-specific notes, all from its own documentation:

- **Leave `ORCA_HOME_DIR` unset.** Dokploy warns that absolute host paths *"will be
  cleaned up during deployments"*. The default named volume is the right choice
  there, and it is also what Dokploy's **Volume Backups** can snapshot. If you do
  want host files, use Dokploy's File Mounts (Advanced → Mounts) or its `../files/...`
  convention rather than an absolute path.
- **`ORCA_PAIRING_ADDRESS` is still required.** Dokploy puts the container behind its
  own networking, so `127.0.0.1` will produce an unreachable pairing link. Use the
  address your client dials.
- **Redeploys are safe.** Dokploy's default command runs `up -d --build
  --force-recreate`. The `--build` is a no-op here (the compose file has no `build:`
  section), `--force-recreate` recreates the container but the named volume outlives
  it, and the pairing link is stable — so a redeploy does not cost you the
  configuration or force clients to re-pair.

Reading the pairing link on Dokploy: open the service's **Logs** tab and search for
`orca://pair`, or use the container terminal if your setup exposes one.

If you want Orca reachable over Tailscale instead of a public address, Dokploy
publishes a Tailscale guide; the pairing address is then the server's `100.x.y.z`
address.

---

## Rootless runtimes

A rootless runtime (rootless Podman, or Docker with userns-remap) maps your host UID
to container UID 0. That matters **only for host bind mounts**: a directory you own
on the host then shows up inside the container as root-owned, and the unprivileged
`orca` user cannot write to it.

**Named volumes are unaffected.** They take their ownership from the image, which
already sets it correctly. This was verified on rootless Podman: zero warnings and a
working worktree with no extra flags.

For a host bind mount — `ORCA_HOME_DIR`, or a repositories mount — add one line:

```yaml
services:
  orca:
    userns_mode: keep-id
```

Do **not** add that on rootful Docker: it only accepts `host` for `userns_mode`.
Rootful Docker maps container UID 1000 straight to host UID 1000 and needs nothing.

On an SELinux host (Fedora, RHEL, CentOS) also set `ORCA_SELINUX_LABEL=:z` in
`.env`. Without it the Unix permissions look correct but the label blocks writes —
the symptom is `Permission denied` on a directory that appears to be owned by you.

The entrypoint warns when it detects any of this, naming the directory it could not
write to, so a misconfiguration is loud rather than silent.

### Changing userns_mode after the volume exists breaks it

A named volume is seeded with the ownership produced by whatever UID mapping was in
effect when it was first created. Adding or removing `userns_mode: keep-id` afterwards
changes that mapping, so the existing volume becomes unwritable to the service user.

The failure is not obvious. Orca does not report a permission problem; it dies with:

```
Fontconfig error: No writable cache directories
[main_uncaught_exception] Error: Failed to get 'userData' path
```

and exits. If you see that after changing `userns_mode`, `PUID`/`PGID`, or `user:`,
recreate the volume:

```bash
docker compose down
docker volume rm orca-headless_orca-home
docker compose up -d
```

State is lost with the volume, so back it up first if it mattered.

---

## ARM64 and Raspberry Pi

The image is published for **`linux/amd64` and `linux/arm64`**. The arm64 build is
what runs on a Raspberry Pi 4, Pi 5, Pi 400, CM4, and any other 64-bit ARM board.

### Which Pi, and which OS

| | Supported |
| --- | --- |
| Pi 4 / Pi 5 / Pi 400 / CM4 with a **64-bit** OS (Raspberry Pi OS 64-bit, Ubuntu arm64) | ✅ |
| Pi Zero, Pi 1, Pi 2, or any Pi running the **32-bit** Raspberry Pi OS | ❌ |
| Pi 3 with the 64-bit OS | ✅ |

Orca publishes only two Linux builds — `orca-linux.AppImage` (x86_64) and
`orca-linux-arm64.AppImage`. **There is no 32-bit ARM build**, so armv7 cannot work
no matter how the image is configured. Check what you have:

```bash
uname -m
# aarch64  -> arm64, supported
# armv7l   -> 32-bit, NOT supported
# armv6l   -> 32-bit, NOT supported
```

On a Pi that reports `armv7l`, reinstall with the 64-bit Raspberry Pi OS. A Pi 3 or
newer supports it; a Pi Zero and Pi 1 do not.

### Memory

This is guidance, not a measurement — no Pi was available to test on. Orca runs a
full Chromium with software rendering, so:

- **4 GB or more** — comfortable.
- **2 GB** — likely workable for a few agents, with swap enabled. Expect pressure.
- **1 GB** — not realistic for Chromium plus agents.

`LIBGL_ALWAYS_SOFTWARE=1` is already set in the image, so no GPU is required. The Pi's
GPU is not used.

### How this is tested

CI runs the image **natively on `ubuntu-24.04-arm`** on every push and pull request:
it builds the arm64 image, asserts the resulting image architecture is really
`arm64`, starts it, waits for the readiness contract, fetches the web client, checks
the bundled skills resolve, and proves a worktree survives a container recreate.
There is no emulation in that job, so a green run means the arm64 image genuinely
starts on ARM hardware.

That covers the container, not a real Pi: the CI runner is Ubuntu arm64, while a Pi
runs Raspberry Pi OS with its own kernel and firmware. If something Pi-specific
breaks, it is worth reporting.

### Building arm64 yourself

```bash
docker buildx build --platform linux/arm64 -t orca-headless:arm64 .
```

You can do this on an amd64 machine: the AppImage is extracted with `unsquashfs` on
the build platform rather than executed, so only the runtime stage needs emulation.

---

## Running like a native install

The short answer: **yes, with `ORCA_HOME_DIR` the container sees the same layout a
native install would, and the only thing that matters is the UID/GID, not the user
name.**

A native Orca install on a Linux server puts everything under the user's home:

```
/home/dev/.config/orca            state
/home/dev/.config/Orca            state (Orca uses both names)
/home/dev/orca/workspaces/...     worktree checkouts
```

Point the deployment at that same home and it is identical:

```bash
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
| **`HOME`** (`ORCA_HOME_DIR`) | Decides *where* Orca puts state and worktrees. This is the one that must match the host path. |

So if your server user is `dev` with uid 1000, you do **not** need to rename
anything: `PUID=1000` and `ORCA_HOME_DIR=/home/dev` already give you a deployment
that behaves natively. The `orca` label never appears in a path you care about.

If you want cosmetic parity too — the account genuinely named `dev`, with `/home/dev`
as its passwd home — build the image with:

```bash
docker build --build-arg ORCA_USER=dev --build-arg PUID=1000 --build-arg PGID=1000 -t orca-headless:dev .
```

That is the only way to change the name, because a non-root process cannot add itself
to `/etc/passwd`. It is not required for anything to work.

---

## Redeploying

`orca serve` never updates itself — upstream is explicit that headless mode wires up
no auto-updater, and the runtime reports
`"remoteUpdateSupport": {"automatic": false, "reason": "updater-unavailable"}`.
Upgrading is always a deliberate step: replace the image, restart.

What each command actually does to your image, your container and your data:

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
- **Redeploying after a `pull` upgrades Orca and still keeps everything.** The volume
  outlives the container, so state, worktrees and projects are untouched and paired
  clients reconnect without re-pairing.

### Is persistence optional?

No — it is what the compose file is for. But *where* it persists is your choice:

- **Named volume** (default). Docker-managed, invisible on the host, survives `down`,
  `up`, `pull` and image rebuilds. Only `down -v` removes it. This is what Dokploy's
  Volume Backups can snapshot.
- **Host directory** (`ORCA_HOME_DIR=/srv/orca/home`). Real files you can inspect and
  back up with normal tools.

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
Conversations may be resumable, but the running process and any in-flight command are
gone. Orca's own upgrade guidance for systemd deployments is the same: do a terminal
census and finish work before restarting.

**Nothing else**, as long as you did not pass `-v`.

### Rolling back

A newer build may rewrite `orca-data.json` in a newer schema, and an older build can
then discard fields it does not recognise. Roll back the **state and the image
together** — restoring the image alone is not safe:

```bash
docker compose down
# restore the volume (or directory) from a backup taken before the upgrade
ORCA_IMAGE=ghcr.io/ivan-cavero/orca-headless:1.4.200 docker compose up -d
```
