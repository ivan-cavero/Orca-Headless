# Contributing

Thanks for wanting to help. This is a small project with one rule: **changes ship
with evidence.** Most of what is in this repository was written after a container
failed in a specific, reproducible way, and the value is in that specificity.

---

## What this project is, and what it is not

**It is** a packaging project. It builds a container image that runs
[Orca](https://github.com/stablyai/orca) headlessly, plus the compose file and scripts
that make it usable on a server without a desktop session.

**It is not** Orca. This repository does not contain Orca's source, does not patch it,
and cannot fix its behaviour.

That distinction decides where a report belongs:

| The problem is | Report it |
| --- | --- |
| Orca itself — an agent does not start, a worktree command misbehaves, the UI is wrong | [stablyai/orca](https://github.com/stablyai/orca/issues) |
| `orca serve` semantics, pairing protocol, readiness contract | [stablyai/orca](https://github.com/stablyai/orca/issues) |
| The image does not build, the container does not start, the healthcheck lies | **here** |
| A path, volume or permission problem specific to running in a container | **here** |
| The compose file, the entrypoint, the scripts, the docs | **here** |

If you are not sure, open it here and say so — we will move it if it belongs upstream.

---

## Reporting a bug

A useful report contains:

- **What you ran** — the exact `docker compose` / `docker run` command, and your
  `.env` with secrets removed.
- **What happened** — the observed output, not a paraphrase of it.
- **What you expected** — and why you expected it.
- **The startup log**, which is where almost everything shows up:

  ```bash
  docker compose logs orca
  ```

  Most of it is expected noise — see
  [Reading the console](docs/troubleshooting.md#reading-the-console). Quote the lines
  you are asking about rather than the whole thing.
- **The healthcheck result**:

  ```bash
  docker compose exec orca orca-healthcheck
  ```

- **Versions**: `docker --version` (or `podman --version`), and the image tag.
  `docker compose exec orca cat /opt/orca/VERSION` gives the Orca build.
- **Your host**: distribution and version, architecture, and whether you are using
  rootless Podman, rootful Docker, or something else.

Please do not paste a pairing URL without revoking the grant afterwards — it is a
credential.

---

## Testing a change

CI runs the same things you can run locally. Do that before opening a pull request.

```bash
# 1. Shell syntax. This catches a real class of bug: a missing `)` in a case
#    pattern once shipped and only surfaced when a container started.
bash -n entrypoint.sh
for script in scripts/*.sh; do sh -n "$script"; done
shellcheck -S warning entrypoint.sh scripts/*.sh

# 2. Documentation links, including #anchors. Run this after moving or renaming
#    any heading.
python3 scripts/check-links.py

# 3. The compose files resolve the way the documentation claims.
docker compose -f docker-compose.yml config
docker compose -f docker-compose.build.yml config
ORCA_HOME_DIR=/srv/orca/home docker compose -f docker-compose.yml config

# 4. Build and run it for real.
docker build -t orca-headless:test .
cp .env.example .env
docker compose up -d
docker compose ps                              # expect: (healthy)
docker compose exec orca orca-healthcheck      # expect: ready on port 6768
docker compose exec orca orca-pairing-url      # expect: a pairing URL
```

### What a change needs to demonstrate

The bar depends on what you touched:

| Touched | Show that |
| --- | --- |
| `Dockerfile` | The image builds and the container reaches `healthy`. |
| `entrypoint.sh` | The container still starts with default config, **and** the specific behaviour you changed, with the observed output. |
| `scripts/healthcheck.sh` | It exits 0 when Orca is ready and non-zero when it is not. Do not just test the happy path. |
| `scripts/pairing-url.sh` | It prints a pairing URL in both `ORCA_JSON=true` and `ORCA_JSON=false` modes. |
| `docker-compose.yml` | `docker compose config` resolves, and `up -d` reaches `healthy`. If you touched volumes, show that state survives a `down` + `up`. |
| `.github/workflows/` | The job graph is what you intend, and no release tag is applied before the smoke test runs. See [How the pipeline is ordered](docs/development.md#how-the-pipeline-is-ordered). |
| Docs | Links resolve (`python3 scripts/check-links.py`), and commands in the docs are ones you actually ran. |

For anything that changes how Orca's files are stored or mounted, **verify that a
worktree survives a container recreate**. That is the failure this project has hit
most often: the metadata in `.config` survives while the checkout does not, so Orca
lists worktrees whose files are gone.

```bash
docker compose exec orca sh -c '
  mkdir -p "$HOME/projects/demo" && cd "$HOME/projects/demo"
  git init -q -b main
  git remote add origin https://github.com/example/demo.git
  git -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
  orca-ide repo add --path "$HOME/projects/demo" --json >/dev/null
  orca-ide worktree create --repo "path:$HOME/projects/demo" --name ci-wt --json >/dev/null
  echo MARKER > "$HOME/orca/workspaces/demo/ci-wt/UNCOMMITTED.txt"'
docker compose down && docker compose up -d
docker compose exec orca cat /home/orca/orca/workspaces/demo/ci-wt/UNCOMMITTED.txt
```

### Changing the pinned Orca version

`ORCA_VERSION` appears in the `Dockerfile`, in `.env.example`, in the CI workflow's
`env:` block, and in the README badge. Update all of them, and confirm the release
asset names are still what the `Dockerfile` expects:

```bash
curl -sI https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage | head -1
```

---

## Commits and pull requests

- **Conventional Commits.** `feat(scope):`, `fix(scope):`, `docs:`, `ci:`, `refactor:`.
  Look at `git log` for the tone — the body explains *why*, and what was observed.
- **No AI attribution.** Do not add `Co-Authored-By` lines or "generated by" notes to
  commits or code.
- **No secrets.** No `.env` files, no pairing URLs, no tokens, no private hostnames or
  paths. `.gitignore` and `.dockerignore` already exclude the usual suspects — do not
  undo that.
- **Keep the scope tight.** A bug fix should not also restructure the docs. Separate
  pull requests are easier to review and easier to revert.
- **Docs are part of the change.** If you change a variable, a path, a default or a
  command, update the relevant file under `docs/` in the same pull request.

If your change adds a new environment variable, it needs three things: a default that
keeps the current behaviour, a row in the table in `docs/configuration.md`, and a
mention in `.env.example` if a user would plausibly set it.

---

## Style

**Shell scripts** — `sh` where possible, `bash` only where needed (the entrypoint uses
process substitution, so it is `bash`). Prefer explicit error handling: the entrypoint
runs under `set -euo pipefail`, and every user-facing failure should name the variable
or directory that caused it.

**Comments explain why, not what.** A comment that restates the code is noise; a
comment recording that `--appimage-extract` leaves `squashfs-root` unreadable to other
users is the reason the `chmod` exists and must not be deleted.

**The compose file is a document.** Its comments are the primary explanation for the
volume layout, and many users will read it before the README. Keep them accurate.

---

## License

By contributing you agree your contribution is licensed under the [MIT License](LICENSE).
See [NOTICE](NOTICE) for the attribution to Orca and its licensors.
