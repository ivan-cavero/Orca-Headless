# Development

## Building the image

```bash
docker build -t orca-headless:local .
```

Or through compose, which also runs it:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

### Build arguments

| Argument | Default | Purpose |
| --- | --- | --- |
| `ORCA_VERSION` | `v1.4.209` | Orca release to download. `latest` works but is not reproducible. |
| `PUID` / `PGID` | `1000` / `1000` | UID/GID of the `orca` user. Must be ≥ 1000. |
| `ORCA_USER` | `orca` | Name of the unprivileged user. Cosmetic — see [Running like a native install](deployment.md#about-the-user-name). |
| `ORCA_EXTRA_PACKAGES` | *(empty)* | Extra apt packages, space-separated. |
| `NODE_VERSION` | *(empty)* | Node.js version to install from nodejs.org. Needed for `orca skills install` and `npm install -g`. Adds ~200 MB. See [Agents and skills](agents-and-skills.md). |
| `UBUNTU_VERSION` | `24.04` | Base image tag. |

### How the build works

Two stages. The AppImage is downloaded, verified as an ELF executable, extracted, and
deleted inside a throwaway stage; only the extracted tree is copied into the runtime
image. That is why FUSE is never needed, and why the ~190 MB AppImage never occupies a
layer of the image you actually run.

The base is `ubuntu:24.04` because it is on Orca's supported matrix and upstream
publishes the exact package list for it — including the `t64` package names from the
64-bit `time_t` transition. Debian 13+ works too but is not what the image is tested
against.

The build also fetches Orca's `LICENSE` for the pinned release and installs it at
`/usr/share/licenses/orca/LICENSE`, because Orca's AppImage does not carry its own
copyright notice and MIT requires the notice to accompany copies. See [NOTICE](../NOTICE).

## Image size

The published image is roughly **1.1 GB** on disk. That is normal for an
Electron/Chromium application, and most of it is not this Dockerfile's doing:

| Layer | Size | What it is |
| --- | --- | --- |
| Extracted Orca app | ~568 MB | Chromium runtime + Orca's application resources |
| System libraries | ~470 MB | The Electron dependency set. `libgbm1` alone pulls `mesa-libgallium` → `libllvm20` (~178 MB), which cannot be dropped without breaking Electron. `git` pulls ~55 MB of Perl. |
| Ubuntu base | ~81 MB | `ubuntu:24.04` |

What this repository *did* optimise: the multi-stage build keeps the 192 MB AppImage
out of the final image entirely, `--no-install-recommends` is used throughout,
`apt-get update` and `install` share a single layer, and the apt lists are removed in
that same layer. Aggressive trimming (dropping unused Electron locales, for example)
was deliberately **not** applied — it saves about 4% and risks breaking localisation
for no real benefit.

## Changing PUID/PGID

PUID and PGID are **build-time** values, so the container's `user:` must match the
image's build arguments. If you change one and not the other, the volume is owned by a
different UID and Orca cannot persist anything — the entrypoint warns you.

```bash
PUID=1500 PGID=1500 docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

Fix the ownership of an existing volume or host directory:

```bash
docker compose down
docker run --rm -v orca-headless_orca-home:/data alpine chown -R 1500:1500 /data
# ORCA_HOME_DIR mode instead:
sudo chown -R 1500:1500 /srv/orca/home
docker compose up -d
```

---

## What was verified

Honest accounting. The following were executed against the built image on **Podman
5.8.7 / Fedora 44, x86_64**, not merely reasoned about:

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
| **Default named volume needs no host directory and no rootless flags** | ✅ rootless Podman, zero warnings, worktree created |
| **`ORCA_HOME_DIR` gives host-identical paths** | ✅ host `git worktree list` accepts the worktree, host can write into it |
| Worktree survives container recreate | ✅ checkout and an uncommitted file both survived; Orca still listed it |
| `orca-ide` resolves on `PATH` in a running container | ✅ |
| Pairing address → advertised endpoint, 7 cases incl. IPv6 and URLs | ✅ unit-tested |
| Port published as `16774:6768` advertises `:16774`, not `:6768` | ✅ |
| State survives `SIGKILL` followed by restart | ✅ stale `SingletonLock` recovered |
| Graceful `SIGTERM` shutdown | ✅ exit 0, immediate |
| `cap_drop: ALL` + `no-new-privileges` | ✅ still reaches ready |
| Wildcard `ORCA_PAIRING_ADDRESS` and non-numeric ports rejected at startup | ✅ exit 1, message names the variable |
| `docker-compose.yml` runs end to end in both storage modes | ✅ via `podman-compose` |
| Unwritable state / workspaces / projects directory produces a warning | ✅ |
| All 8 bundled skills print offline with `skills get` | ✅ 104–376 lines each |
| `skills install` lands in `$HOME/.agents/skills/` and persists a recreate | ✅ |
| Ubuntu 24.04's Node 18 is too old for the community `skills` CLI | ✅ fails with a `styleText` error |
| `npm install -g` as non-root fails; as root succeeds | ✅ both observed |
| A real agent installs and Orca auto-detects it | ✅ `@openai/codex` 0.156.1 |
| Orca creates a real, connected PTY in a worktree | ✅ `connected: true`, `writable: true` |
| Orca opens the container's bash, not the host's shell | ✅ zsh and fish absent from the image |
| Host dotfiles load only when `ORCA_HOME_DIR` points at that home | ✅ verified with a marker in a custom `.bashrc` |
| Node 24 LTS works for `skills install` and `npm install -g` | ✅ v24.21.0, npm 11.19.0 |
| A host agent binary runs inside the container via bind mount | ✅ real `opencode` 1.18.32 |
| An already-paired client survives a `--mobile-pairing` restart | ✅ still connected |
| A home with mode `700` works | ✅ verified as uid 1001 |
| Orca's `opencode-binder` reads `$HOME/.local/share/opencode/opencode.db` | ✅ and skips with a non-fatal error when it is absent |
| `engram` (static ELF) runs in the container | ✅ `engram 2.0.0` |
| `pi` needs Node; the entrypoint picks up nvm's | ✅ `pi 0.85.1` after the nvm path is added |
| A read-only `~/.local` breaks opencode | ✅ `EACCES: mkdir /home/.../.local/state/opencode` |
| The real **arm64** AppImage extracts without emulation | ✅ 3613 files, executable AppRun, `orca-ide` is aarch64 |
| Orca publishes no 32-bit ARM build | ✅ only `orca-linux.AppImage` and `orca-linux-arm64.AppImage` exist |

### Not verified, and worth knowing

- **The arm64 container has not been started outside CI.** The arm64 AppImage was
  downloaded and extracted on an amd64 host, which proves the packaging path but not
  that the container boots on ARM. CI now runs the image natively on
  `ubuntu-24.04-arm` on every push and pull request to cover exactly that — but that
  job was added after the last green run, so its first result is still pending.
- **No real Raspberry Pi has run this.** The CI runner is Ubuntu arm64; a Pi runs
  Raspberry Pi OS with its own kernel and firmware. See
  [ARM64 and Raspberry Pi](deployment.md#arm64-and-raspberry-pi).
- **The GHCR publish workflow has only been executed once, and that run failed.**
  The failure was in the multi-arch build, diagnosed as QEMU being unable to execute
  the AppImage's `static-pie` runtime, and fixed by extracting with `unsquashfs`
  instead. The subsequent run was green, including the arm64 leg of the build.
- **Docker Engine itself was not used locally** — Podman was, because that is what
  the development environment had. The CI runs use Docker Engine and are green.
- **Dokploy was not tested.** Its behaviour described in these docs is taken from its
  own documentation, not from running it.
- **No GUI client was run.** The pairing flow was verified with `orca-ide environment
  add` / `status --environment`, which performs the same WebSocket handshake the
  desktop and mobile clients perform, plus an HTTP fetch of the web client and a raw
  WebSocket upgrade. That is strong evidence, not the same thing as a human clicking
  **Add Server**.
- **Nine of the ten supported agent harnesses were not installed.** Only `codex` was
  installed for real. See [Agents and skills](agents-and-skills.md).

---

## How the pipeline is ordered

```
lint ──> build (pushes :sha-<commit>) ──> smoke-test (amd64 + arm64, native) ──> publish (release tags)
                                     └──> scan (Trivy ──> Security tab)
```

The order is the point. The build job publishes **only** an immutable
`sha-<commit>` tag. `latest`, the branch tag and the semver tags are added by the
publish job, and only after the smoke test has run the image on both architectures.
Publishing `latest` at build time would mean a broken image is already live while it
is still being verified.

`publish` retags the existing multi-arch manifest with `docker buildx imagetools
create`. It does not rebuild anything, so the bytes that were smoke tested are the
bytes that ship.

On a push, the smoke test **pulls the published `sha` image** rather than rebuilding
it, so what gets verified is the artifact that will be promoted — not a local rebuild
that happens to match. On a pull request nothing is published, so it builds locally.

### The vulnerability scan is deliberately non-blocking

Every published image is scanned with Trivy for `CRITICAL` and `HIGH` findings with a
fix available, and the results land in the repository's **Security** tab.

It does not fail the build. The image carries roughly 470 MB of distribution packages
and most findings have no upstream fix; failing would block every build on something
nobody can act on. Triage happens in the Security tab. See
[SECURITY.md](../SECURITY.md).

### Old image versions are cleaned up weekly

Every push leaves behind an immutable `sha-<commit>` version. A scheduled workflow
(`cleanup-image-versions.yml`) deletes the older ones.

It is deliberately conservative: a version is only eligible when **every** tag it
carries starts with `sha-`. The promoted version always carries `latest` or `main`,
so it can never be selected — including the case where a publish failed and `latest`
is still pointing at an older build, which is exactly when deleting by age alone
would break the image for every user. The twenty most recent sha-only versions are
kept as a safety net.

Layers are shared between builds, so this is tag hygiene rather than storage
pressure. A manual run defaults to a dry run:

```bash
gh workflow run cleanup-image-versions.yml -f dry_run=true
```

---

## Testing a change

Before opening a pull request, run what CI runs:

```bash
# shell syntax — this catches the class of bug that once shipped
bash -n entrypoint.sh
for script in scripts/*.sh; do sh -n "$script"; done
shellcheck -S warning entrypoint.sh scripts/*.sh

# compose files parse and resolve the way the docs claim
docker compose -f docker-compose.yml config
docker compose -f docker-compose.build.yml config
ORCA_HOME_DIR=/srv/orca/home docker compose -f docker-compose.yml config
```

Then build and actually run it:

```bash
docker build -t orca-headless:test .
cp .env.example .env
docker compose up -d
docker compose exec orca orca-healthcheck     # expect: ready on port 6768
docker compose exec orca orca-pairing-url     # expect: a pairing URL
```

A change that touches the entrypoint, the healthcheck, the compose file or the
Dockerfile should come with evidence that the container still reaches `healthy` and
that a worktree still survives a recreate. See [CONTRIBUTING](../CONTRIBUTING.md).
