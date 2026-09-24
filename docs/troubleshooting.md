# Troubleshooting

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
| `[secrets] The OS keyring is unavailable` | **Real.** No keyring, so secrets are stored unencrypted in the state directory. See [Security](security.md#secrets-are-stored-unencrypted). |
| `spawn codex ENOENT` / `spawn claude` | **Real but non-fatal.** The agent CLI is not installed, so that agent cannot run. Orca still serves. See [Agent CLIs](#spawn-codex-enoent-or-spawn-claude). |
| `[serve] orca CLI install: installed` | **Informational.** The CLI is now on `PATH` inside the container. |
| `Another Orca instance is already running` | **Fatal, exit 3.** A profile lock. See [below](#another-orca-instance-is-already-running-for-this-userdata-profile). |
| `{"type":"orca_server_ready",...}` | **The readiness contract.** Orca is serving. This is what the healthcheck waits for. |

The line that decides whether the container is usable is the last one. Everything
before it is either noise or a warning you can act on later.

### Why the D-Bus noise cannot be removed

It is worth recording, because it looks fixable and is not.

Chromium logs two kinds of D-Bus failure: one for the **session** bus and one for the
**system** bus at `/run/dbus/system_bus_socket`. Measured on a real container: ten
lines without anything, six with a session `dbus-daemon` running. Providing the
session bus removes four of them and adds a `dbus` package plus a daemon process.

The remaining six are the system bus, which needs a second daemon running as root, and
Orca's own keyring notice, which needs an unlocked keyring — the thing that does not
exist in a headless container in the first place. Fully silencing the log would mean
turning the container into something close to a desktop, for output that is
informational.

`DBUS_SESSION_BUS_ADDRESS=disabled:` does not help either; measured, it changes
nothing.

So the entrypoint names the noise before it appears instead, and the readiness line
stays the thing to look for.

To see only what matters:

```bash
docker compose logs orca | grep -E 'orca_server_ready|\[entrypoint\]|secrets|ENOENT'
```

---

## I cannot find the pairing link

```bash
docker compose exec orca orca-pairing-url
```

If it reports no link, see
[If there is no link](pairing.md#if-there-is-no-link) — the log carries a stable
reason code.

## The client cannot connect

Nine times out of ten it is `ORCA_PAIRING_ADDRESS`. Check what was advertised:

```bash
docker compose logs orca | grep -o '"advertisedEndpoint":"[^"]*"' | tail -1
```

That value is what the client dials. If it says `127.0.0.1`, or an address the client
cannot route to, fix `.env` and `docker compose up -d`. Then confirm the port is
reachable from outside:

```bash
nc -z <server-ip> 6768 && echo open
```

If you changed the published host port, set `ORCA_HOST_PORT` to match — the entrypoint
derives the advertised port from it. See [Ports](configuration.md#ports).

## `spawn codex ENOENT` (or `spawn claude`)

The agent CLI is not installed in the container. Orca starts and serves fine, but that
agent cannot be launched. This is the most common first-run surprise.

Mount a directory that already has them:

```yaml
volumes:
  - /home/you/.local/bin:/home/orca/.local/bin:ro
```

Or build an image with them installed — the reproducible option. Node is a build
argument because Ubuntu 24.04's own `nodejs` is too old for the tooling:

```bash
docker build --build-arg NODE_VERSION=24.21.0 -t orca-headless:node .
```

```dockerfile
FROM orca-headless:node
USER root
# npm's global prefix is /usr, so this must run as root. As the unprivileged
# user it fails with a permissions error.
RUN npm install -g @openai/codex
USER orca
```

Then authenticate from inside the container, since a login on your laptop does not
carry over:

```bash
docker compose exec orca sh
orca-ide account add --agent claude
orca-ide account add --agent codex
orca-ide account list
```

**Orca does not see the agents installed on your host by default.** A container is
isolated: Orca launches agents from `PATH` in its own environment. A host binary can
be bind-mounted and it will work if it is portable — see
[Running agents from the host](agents-and-skills.md#running-agents-from-the-host) —
but the default image contains none. See
[Agents and skills](agents-and-skills.md#the-container-boundary) for the full model,
including where skills are installed and why `npm install -g` needs root.

## Worktrees disappear after `docker compose down`

`$HOME/orca` is not persisted. Orca creates worktree checkouts under
`$HOME/orca/workspaces`, not inside the repository you import; the metadata lives in
`.config` and survives, so Orca lists worktrees whose files are gone. The bundled
compose file mounts the whole home, so this only happens if you wrote your own volume
list. See [Where everything lives](deployment.md#where-everything-lives).

## `Imported folder does not match the selected project identity`

Orca identifies projects by their git remote. Add an `origin` and use the derived id
(`github:owner/repo`). A folder with no remote cannot be imported.

## `orca-ide: not found`

`orca serve` registers the CLI into `$HOME/.local/bin`. The image also exposes it at
the fixed path `/opt/orca/bin/orca-ide`, which is on `PATH` regardless of `HOME`. If
you overrode `HOME` yourself, use that absolute path or add `$HOME/.local/bin` to
`PATH`.

## `Permission denied` on a mounted directory

Two distinct causes, and the entrypoint names the directory it could not write:

- **Rootless runtime with a host bind mount.** Your host UID maps to container UID 0,
  so the mount is root-owned inside the container. Add `userns_mode: keep-id` to the
  service. Named volumes are unaffected — this only happens with `ORCA_HOME_DIR` or a
  repositories mount.
- **SELinux host.** Unix permissions look correct but the label blocks writes. Set
  `ORCA_SELINUX_LABEL=:z` in `.env`.

See [Rootless runtimes](deployment.md#rootless-runtimes).

## State does not persist after `down`

Check the container actually got the mount:

```bash
docker inspect orca --format '{{range .Mounts}}{{.Destination}}{{"\n"}}{{end}}'
```

You should see `/home/orca` (or your `ORCA_HOME_DIR`). If you overrode `user:` to a UID
different from the image's `PUID`, the volume is owned by someone else and Orca
silently fails to write. See
[Changing PUID/PGID](development.md#changing-puidpgid).

## `Another Orca instance is already running for this userData profile`

Orca exits with status **3** when something else already owns the same userData
profile. Find the owner, stop it, and restart. If nothing owns it, the lock is stale —
remove `SingletonLock` and `SingletonSocket` from the state directory:

```bash
docker compose down
docker run --rm -v orca-headless_orca-home:/data alpine \
  rm -f /data/.config/orca/SingletonLock /data/.config/orca/SingletonSocket
docker compose up -d
```

This was tested: a `SIGKILL` leaves those files behind and Orca recovers from them on
the next start. You should not normally need this.

## `dlopen(): error loading libfuse.so.2`

You are running an AppImage directly without FUSE. This image never hits that path —
it extracts the AppImage at build time and runs the extracted tree, so `libfuse2` is
not needed at all. If you see this while running the AppImage yourself, either install
`libfuse2` (Ubuntu 22.04) / `libfuse2t64` (Ubuntu 24.04) or use `--appimage-extract`
once and run `squashfs-root/AppRun`.

## The container is `unhealthy` but clients work

The healthcheck requires Orca's readiness line in `/tmp/orca-serve.log` **and** an open
listener. Check the log:

```bash
docker compose exec orca cat /tmp/orca-serve.log
```

## Container restarts in a loop

```bash
docker compose logs --tail=100 orca
```

Exit status 3 means a profile lock (above). Any other immediate exit usually means a
bad `ORCA_PAIRING_ADDRESS`, `ORCA_PORT` or `ORCA_HOME_DIR` — all are validated at
startup and fail fast with a message naming the variable.

## The healthcheck never passes on a slow host

`start_period` is 90s and failures during it do not count towards `retries`. If the
first boot is migrating a large state directory it can take longer; raise
`start_period` in the compose file.
