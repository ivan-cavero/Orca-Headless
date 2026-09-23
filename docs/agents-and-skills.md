# Agents and skills

This page explains where things live when Orca runs inside a container, because the
answer is different from a native install in one important way.

---

## The container boundary

**Orca launches agents from `PATH` inside its own environment. A container is
isolated, so Orca in the container cannot see or run the agents installed on the
host.**

This was verified, not assumed. On the machine used to build these docs:

| Agent | On the host | Inside the container |
| --- | --- | --- |
| `claude` | `/home/…/.local/bin/claude` | not found |
| `opencode` | `/home/…/.bun/bin/opencode` | not found |
| `grok` | `/home/…/.grok/bin/grok` | not found |
| `cursor-agent` | `/home/…/.local/bin/cursor-agent` | not found |

The container could not even see `/home/<hostuser>`. The container is still isolated —
Orca reads `PATH` inside it, not the host's — but a host binary **can** be mounted in
and it will work if it is portable. That was verified with a real `opencode`, see
[Running agents from the host](#running-agents-from-the-host).

The practical consequence: an agent conversation lives in the container, with the
container's credentials and the container's filesystem. A login on your laptop does
not carry over, and a login inside the container does not exist on your laptop.

**You do not have to install the agent inside the image.** A host binary can be
bind-mounted and Orca will find it, provided it is portable. See
[Running agents from the host](#running-agents-from-the-host) — verified with a real
`opencode`.

---

## Two different things are called "skills"

### 1. Bundled guides — already in the image

These are Orca's own operating instructions for agents: how to drive the `orca` CLI,
how to coordinate workers, how to use Computer Use.

They ship **inside the image**, in the app bundle:

```
/opt/orca/app/resources/skills/
├── current-manifest.json     what skills exist, with content hashes
├── release-mapping.json
└── snapshot-registry.json    the guides themselves
```

You can read any of them without Node, without network, and without a running
runtime:

```bash
docker compose exec orca orca-ide skills get orchestration
docker compose exec orca orca-ide skills get orca-cli | head -40
```

The eight bundled skills, with the line count each one prints:

| Skill | Lines | What it covers |
| --- | --- | --- |
| `orca-cli` | 248 | Worktrees, terminals, repos, artifacts, the embedded browser |
| `orchestration` | 197 | Supervised workers, task DAGs, decision gates |
| `computer-use` | 153 | Driving a GUI through `orca computer` |
| `orca-per-workspace-env` | 376 | Per-workspace environment recipes |
| `linear-tickets` | 162 | Legacy name for `orca-linear` |
| `orca-linear` | 162 | Linear ticket workflow |
| `orca-emulator` | 104 | iOS Simulator control (macOS) |
| `orca-emulator-android` | 118 | Android device and emulator control over adb |

These need nothing extra. They are the reason an agent inside the container can still
be told how to operate Orca.

### 2. Installed skills — copied into agent config directories

`orca skills install` takes those same guides and **copies the `SKILL.md` files into
the directories your coding agents read**, so an agent that has never heard of Orca
picks them up as ordinary skills.

Verified: they land in the shared directory Orca reads, and they persist because that
directory is inside the volume.

```
/home/orca/.agents/skills/<name>/SKILL.md
/home/orca/.agents/.skill-lock.json
```

```bash
docker compose exec orca orca-ide skills installed        # what is installed
docker compose exec orca orca-ide skills install --skill orca-cli --skill orchestration --agent universal
docker compose exec orca orca-ide skills update --all
```

### `~/.agents/skills` is the cross-tool convention

That directory is not an Orca invention. The community CLI behind `skills install` is
[`vercel-labs/skills`](https://github.com/vercel-labs/skills), and `.agents/skills/`
is its **Universal** target — the shared location that many agents read in addition to
their own:

| Agent | Project path | Global path |
| --- | --- | --- |
| Universal, Amp, Replit | `.agents/skills/` | `~/.agents/skills/` |
| Codex | `.agents/skills/` | `~/.codex/skills/` |
| Claude Code | `.claude/skills/` | `~/.claude/skills/` |
| Cline, Zed, Warp, … | `.agents/skills/` | per-agent |

The ecosystem knows about 68 agents. Orca reads `$HOME/.agents/skills` itself — it
reports those entries as **"Agent skills home"** — so installing with
`--agent universal` is enough for Orca and for any other agent that follows the
convention.

Two consequences worth knowing:

- **Installing into the volume is the right place.** `$HOME/.agents` is inside the
  Orca volume, so skills survive a redeploy automatically. That is the default.
- **With `ORCA_HOME_DIR` pointed at your real home, `$HOME/.agents` is your host
  user's `~/.agents`.** Skills installed from inside the container then appear to the
  agents you run on the host, and vice versa. With the default named volume they are
  private to the container.

> The exact global path depends on the CLI version. `skills@1.7.0` — the version
> `npx --yes skills` currently resolves to — writes `~/.agents/skills/`, which is
> what was observed here. The upstream README documents `~/.config/agents/skills/`
> for a newer release, so treat the path as version-dependent and check
> `orca-ide skills installed` rather than assuming.

`orca skills install` resolves to the community CLI:

```
npx --yes skills add https://github.com/stablyai/orca --skill <name> --global --agent <target> -y
```

Two things follow from that, both verified:

- **It needs Node >= 22.20.** Ubuntu 24.04's own `nodejs` is 18 and the install
  fails with `SyntaxError: The requested module 'node:util' does not provide an
  export named 'styleText'`. This is why Node is a build argument rather than
  something you can just `apt install` later.
- **It needs network access** at the moment you run it, because it fetches the
  community `skills` CLI.

Without `--agent`, Orca targets the agents it detects plus the shared
`.agents/skills` directory. With no agent detected at all it refuses to guess rather
than installing into every agent the community CLI knows about:

```
No coding agent detected on this host, so there is no install target. Pass
--agent <name>[,<name>...] to choose targets explicitly — --agent universal writes
only the shared .agents/skills directory that Orca reads.
```

`--agent universal` is the right choice when you only want the shared directory.

---

## How Orca detects agents

Orca looks for each agent's executable on `PATH` in its own environment. Verified by
installing a stub named `codex` inside a running container: Orca detected it
immediately and started targeting it.

```bash
# before the stub
$ orca-ide skills install --skill orchestration --dry-run
npx --yes skills add https://github.com/stablyai/orca --skill orchestration --global --agent universal -y

# after dropping a stub at ~/.local/bin/codex
$ orca-ide skills install --skill orchestration --dry-run
npx --yes skills add https://github.com/stablyai/orca --skill orchestration --global --agent codex --agent universal -y
```

The harnesses Orca knows about, as referenced in its own bundle:

`claude`, `codex`, `opencode`, `gemini`, `grok`, `copilot`, `amp`, `aider`, `goose`,
`cursor-agent`.

Orca runs them in real PTYs inside worktrees. Verified: `orca-ide terminal create
--worktree active --command <agent>` creates a connected, writable terminal whose
working directory is the worktree checkout.

---

## Running agents from the host

You do not have to bake the agent into the image. Bind-mount the directory that holds
it and put it on `PATH`, and Orca finds it exactly as if it had been installed:

```yaml
services:
  orca:
    environment:
      # The agent paths are the HOST paths, because that is where the mount puts
      # them. See "Mount binaries at their own path" below for why.
      PATH: /home/you/.bun/bin:/home/you/.local/bin:/home/you/.grok/bin:/opt/orca/bin:/usr/local/bin:/usr/bin:/bin
    volumes:
      # Binaries: mounted at their own absolute path on the host.
      - /home/you/.bun:/home/you/.bun:ro,z
      - /home/you/.local:/home/you/.local:ro,z
      - /home/you/.grok:/home/you/.grok:ro,z
      # Configuration and skills: at the container's home, where agents look.
      - /home/you/.agents:/home/orca/.agents:ro,z
      - /home/you/.config/opencode:/home/orca/.config/opencode:ro,z
```

### Mount binaries at their own path, not at the container's home

This is the part that is easy to get wrong, and it does not look like a path
problem when it fails.

Agent installers put a symlink in `~/.local/bin` or `~/.bun/bin` that points at a
**versioned absolute path**:

```
/home/you/.local/bin/claude -> /home/you/.local/share/claude/versions/2.1.217
```

Mount that directory at `/home/orca/.local` and the symlink still says
`/home/you/.local/...`, which does not exist inside the container. The symlink
dangles, `command -v claude` finds nothing, and Orca reports no agent — while the
binary is sitting right there. It reads like a libc problem and is not one.

Mount the binary directories at **their own absolute path** and the symlinks resolve.
Configuration and skills are different: agents look for those under `$HOME`, which is
`/home/orca`, so those mounts target the container path.

Verified against a real `opencode` (a Bun-compiled binary, 176 MB):

| Check | Result |
| --- | --- |
| The host binary executes inside the container | ✅ `opencode --version` → `1.18.32` |
| Orca resolves it on `PATH` | ✅ `/home/orca/.bun/bin/opencode` |
| Orca targets it for `skills install` | ✅ `--agent opencode --agent universal` |
| Orca reads the mounted `~/.agents/skills` | ✅ the host's skills listed as "Agent skills home" |
| Container reaches `healthy` | ✅ zero warnings |
| Several harnesses mounted at once | ✅ Orca detected `claude-code`, `grok`, `hermes-agent`, `opencode`, `pi` |
| `claude` runs from the host mount | ✅ `2.1.217 (Claude Code)` |
| The host's `~/.config/opencode` is readable | ✅ `AGENTS.md`, `commands/`, `node_modules/` |
| Mounting at a different path breaks absolute symlinks | ✅ `claude` became "not found" until the mount used the host path |

### Why it works, and when it will not

The binary is dynamically linked, and the host's glibc (2.43 on Fedora) is **newer**
than the container's (2.39 on Ubuntu 24.04). It still ran, because Bun targets an old
glibc baseline for portability. That is luck rather than a guarantee:

- **A binary built against a newer glibc than the container's will fail** with a
  version error. If that happens, the agent has to be installed inside the image
  instead.
- **The architecture must match.** An arm64 binary will not run in an amd64 container.
- **On SELinux hosts the mount needs `:z`.** Without it the container gets
  `Permission denied` even though the file is world-executable — which is exactly how
  the first attempt at this failed.
- **Anything the agent resolves relative to its own path** — bundled runtimes, plugin
  directories, credential stores — has to come along in the mount, or be reachable at
  the path the agent expects.

Mounting is the right choice when you want the same agent, skills and configuration
you already use on the host, kept in one place. Installing into the image is the
right choice when you want the deployment to be reproducible from the image alone.

---

## Installing an agent in the image

Node is opt-in, because most deployments do not need it and it costs about 200 MB.
Build with it when you do:

```bash
docker build --build-arg NODE_VERSION=24.21.0 -t orca-headless:node .
```

**Use an LTS release.** `24.21.0` is the current LTS ("Krypton") and is what was
tested; `22.23.2` ("Jod") is the previous LTS and also works, since the community CLI
only requires `>= 22.20.0`. The version is pinned rather than resolved at build time
so the image stays reproducible — check
[nodejs.org](https://nodejs.org/en/about/previous-releases) for the current LTS and
bump the argument.

Or through compose, by adding the argument to `docker-compose.build.yml`:

```yaml
    build:
      args:
        NODE_VERSION: "24.21.0"
```

Then install the agent **as root**, because npm's global prefix is `/usr`:

```dockerfile
FROM orca-headless:node
USER root
RUN npm install -g @openai/codex
USER orca
```

Verified: this puts `codex` at `/usr/bin/codex`, it resolves for the unprivileged
`orca` user, `codex --version` reports `codex-cli 0.156.1`, and Orca detects it.

Running `npm install -g` as the unprivileged user **fails** with a permissions error
— the prefix is `/usr`. That is a real trap and the reason the recipe switches user.

### Where installed agents live, and what that means

| Installed in | Survives a redeploy | Notes |
| --- | --- | --- |
| The image (`npm install -g` as root) | yes, it *is* the image | Reproducible. This is the recommended path. |
| `$HOME/.local` inside the volume | yes | Survives `down` + `up`; lost on `down -v`. Needs `npm config set prefix` first. |
| `$HOME/.local/bin` bind-mounted from the host | yes | The binaries must match the container's libc. |

Skills are different: they live in `$HOME/.agents`, which is inside the volume, so
**skills survive a redeploy automatically** once installed.

---

## Terminals inside Orca

Orca opens a real PTY in the worktree checkout. Verified: `connected: true`,
`writable: true`, and its working directory is the worktree path.

**The shell is the container's, not your host's.** Orca uses `/bin/bash`, taken from
the image's `/etc/passwd` entry for the `orca` account. It does not consult your
host's `$SHELL`.

That leads to a difference between the two storage modes:

| | Default (named volume) | `ORCA_HOME_DIR` = your real home |
| --- | --- | --- |
| `~/.bashrc` in the terminal | Ubuntu's stock one, from the base image | **yours** |
| Your prompt, aliases, functions | not present | loaded |
| Verified marker from a custom `.bashrc` | `NOT-SET` | `host-dotfile-loaded` |

So if you have a carefully tuned shell and you want it inside Orca, point
`ORCA_HOME_DIR` at your home — the same variable that gives you host-identical paths
also brings your dotfiles. With the default volume you get a clean Ubuntu bash.

Two limits apply either way:

- **zsh and fish are not installed.** The image has `bash`, `dash` and `sh`. If your
  shell is zsh, Orca opens bash regardless. Add `zsh` through `ORCA_EXTRA_PACKAGES`
  if you need it, and note that the `orca` account's login shell in `/etc/passwd`
  would still be bash.
- **The host home is not mounted by default.** With the named volume the container
  cannot see `/home/<you>` at all, so no host dotfile, binary or credential is
  reachable from a terminal.

---

## What was verified, and what was not

Verified against a real image:

| Check | Result |
| --- | --- |
| All 8 bundled skills print offline with `skills get` | ✅ 104–376 lines each |
| `skills install` lands in `$HOME/.agents/skills/<name>/SKILL.md` | ✅ |
| Installed skills persist across a container recreate | ✅ |
| Ubuntu 24.04's Node 18 is too old for the community `skills` CLI | ✅ fails with a `styleText` error |
| Node 22 from the official tarball works, pinned by version | ✅ |
| `npm install -g` as non-root fails; as root succeeds | ✅ both observed |
| A real agent (`@openai/codex` 0.156.1) installs and resolves for the non-root user | ✅ |
| Orca auto-detects an agent present on `PATH` | ✅ with a stub and with the real one |
| Orca creates a real, connected PTY in a worktree | ✅ `connected: true`, `writable: true` |
| Orca opens the container's `/bin/bash`, not the host's `$SHELL` | ✅ `/etc/passwd` shell is `/bin/bash`; zsh and fish absent |
| A custom `.bashrc` on the host is **not** loaded with the named volume | ✅ marker reads `NOT-SET` |
| A custom `.bashrc` **is** loaded when `ORCA_HOME_DIR` points at that home | ✅ marker reads `host-dotfile-loaded`, interactive and login |
| Node 24 LTS works for `skills install` and `npm install -g` | ✅ v24.21.0, npm 11.19.0 |
| A host agent binary runs inside the container via bind mount | ✅ `opencode` 1.18.32, built against glibc 2.43, ran on the container's 2.39 |
| Orca detects and targets that mounted agent | ✅ `--agent opencode --agent universal` |
| Orca reads the host's `~/.agents/skills` when mounted | ✅ listed as "Agent skills home" |
| The mount needs `:z` on an SELinux host | ✅ without it: `Permission denied` |
| **An already-paired desktop client survives `--mobile-pairing`** | ✅ still `connected` while a mobile-scoped link is emitted |

**Not verified:**

- **Nine of the ten harnesses.** Only `codex` was installed for real. The others are
  listed from Orca's own bundle, not from a working install.
- **An actual agent session.** No prompt was sent to any agent; the PTY was created
  and the binary resolved, but no conversation ran.
- **Authentication for any agent.** That is per-vendor and per-account.
- **`computer-use` and the emulator skills on Linux.** `computer-use` drives a visible
  app window and `orca-emulator` targets macOS; neither is exercised here.
