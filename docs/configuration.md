# Configuration

Every variable is optional. Copy `.env.example` to `.env` and edit.

| Variable | Default | Purpose |
| --- | --- | --- |
| `ORCA_PAIRING_ADDRESS` | `127.0.0.1` | **Set this for any remote client.** Address clients dial. Hostname, IP, Tailscale address, or a full `https://` reverse-proxy URL. Wildcards (`0.0.0.0`, `*`, `::`) are rejected at startup. |
| `ORCA_HOME_DIR` | *(empty)* | Absolute host path to store everything in, instead of the named volume. See [Where everything lives](deployment.md#where-everything-lives). |
| `ORCA_PORT` | `6768` | Port Orca listens on inside the container. |
| `ORCA_HOST_PORT` | `6768` | Port published on the host. Keep the `ports:` mapping in sync; the entrypoint uses this to build the advertised endpoint. |
| `ORCA_IMAGE` | `ghcr.io/ivan-cavero/orca-headless:latest` | Image to run. Change it if you forked or build locally. |
| `PUID` / `PGID` | `1000` / `1000` | UID/GID the container runs as. **Build-time** arguments; see [Changing PUID/PGID](development.md#changing-puidpgid). |
| `ORCA_SELINUX_LABEL` | *(empty)* | `:z` on SELinux hosts (Fedora/RHEL/CentOS) when using a host bind mount. |
| `ORCA_JSON` | `true` | `true` emits the versioned single-line JSON contract; `false` emits the human-readable `Orca server ready` block and a scannable QR with `--mobile-pairing`. |
| `ORCA_NO_SANDBOX` | `true` | Adds Chromium's `--no-sandbox`. Read [Security](security.md) before changing. |
| `ORCA_EXTRA_ARGS` | *(empty)* | Extra flags appended to `orca serve`: `--mobile-pairing`, `--no-pairing`. |
| `ORCA_VERSION` | `v1.4.210` | Orca release baked in. Only read when building locally. |

Inside the container these are set as `ENV` as well, so `docker compose exec orca sh`
sees them.

---

## Ports

### The published-port trap, and how the entrypoint fixes it

Orca builds the advertised endpoint from the address you give it plus **the port it
bound inside the container** — not the port you published. So publishing
`-p 16774:6768` while advertising a bare `10.0.0.5` hands clients
`ws://10.0.0.5:6768`, where nothing is listening.

The entrypoint prevents this. It appends `ORCA_HOST_PORT` when the pairing address
is a bare host or bare IPv6, and leaves the address alone when it already carries a
port or is a full reverse-proxy URL:

| `ORCA_PAIRING_ADDRESS` | `ORCA_HOST_PORT` | advertised |
| --- | --- | --- |
| `10.0.0.5` | `16774` | `ws://10.0.0.5:16774` |
| `orca.mydomain.dev` | `16774` | `ws://orca.mydomain.dev:16774` |
| `10.0.0.5:443` | `16774` | `ws://10.0.0.5:443` (explicit wins) |
| `https://orca.example.com/runtime` | any | `wss://orca.example.com/runtime` |
| `[fd00::1]` | `16774` | `ws://[fd00::1]:16774` |
| `fd00::1` | `16774` | `fd00::1` (bare IPv6, unchanged) |

So to publish a different host port you only change `ORCA_HOST_PORT`, and the
mapping, the advertised endpoint and the pairing code stay consistent.

`--pairing-address` is only *advertised*. It never changes where Orca listens:
inside the container Orca always binds `0.0.0.0`, and Compose publishes the port.

---

## Paths

Three paths matter, and each has one job. All three live inside the single volume.

| Container path | Job |
| --- | --- |
| `$HOME/.config` | Orca's state: projects, worktree metadata, terminal history, orchestration state, paired-device keys. Orca uses **both** `.config/orca` and `.config/Orca`. |
| `$HOME/orca/workspaces` | The actual worktree checkouts. **Orca creates these here, not inside the repo you import.** |
| `$HOME/projects` | The repositories you import into Orca. |

With the default named volume `$HOME` is `/home/orca`; with `ORCA_HOME_DIR` it is
that path instead.

Two mistakes are easy to make and expensive:

- **Not persisting `$HOME/orca`.** The metadata in `.config` survives a recreate but
  the checkouts do not, so Orca lists worktrees whose files are gone. The bundled
  compose file mounts the whole home, so this cannot happen unless you write your own
  volume list.
- **Mounting the same named volume at both `.config/orca` and `.config/Orca`.**
  Docker presents the same directory contents at both paths, which is not what Orca
  expects. Mount the parent.

### Importing a project

Orca identifies a project by its **git remote**, not by a folder name. A folder with
no `origin` remote cannot be imported — `project setup-existing-folder` fails with
*"Imported folder does not match the selected project identity."* The project id is
derived from the remote, for example `github:owner/repo`.

For remote runtimes the path you pass must be an **absolute path inside the
container**:

```bash
docker compose exec orca orca-ide repo add --path /home/orca/projects/repo --json
```

That path is `/home/orca/projects/...` with the default volume, or
`/srv/orca/home/projects/...` when you set `ORCA_HOME_DIR=/srv/orca/home`. Orca
records whatever you pass, so pick a stable path and keep it.

### Putting repositories on their own host directory

If you want the repos outside the volume — for example because they are large and you
do not want them in your state backups — add a second mount to the service:

```yaml
    volumes:
      - ${ORCA_HOME_DIR:-orca-home}:${ORCA_HOME_DIR:-/home/orca}
      - /srv/repos:/home/orca/projects
```

That only makes sense while `ORCA_HOME_DIR` is unset, because it targets
`/home/orca/projects`. With `ORCA_HOME_DIR` set, the projects directory is already on
the host, inside the mounted home.

---

## Backups

```bash
# named-volume mode
docker run --rm -v orca-headless_orca-home:/data -v "$PWD":/backup \
  alpine tar czf /backup/orca-state-$(date +%F).tgz -C /data .

# ORCA_HOME_DIR mode
sudo tar czf orca-state-$(date +%F).tgz -C /srv/orca/home .
```

Restoring is the reverse. Remember that a newer Orca build may have migrated
`orca-data.json` to a newer schema, so restore the state and the image version
together — see [Rolling back](deployment.md#rolling-back).
