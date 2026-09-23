# Security Policy

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private reporting instead: go to the **Security** tab of this
repository and choose **Report a vulnerability**. That opens a private advisory
visible only to the maintainers.

If you cannot use that, open a public issue that says only that you have a security
report and would like a private channel — without any detail — and a maintainer will
follow up.

Please include, as far as you can:

- What the problem is and what an attacker gains.
- How to reproduce it: the image tag, the compose file, the environment variables
  (secrets removed) and the commands.
- Whether it affects this packaging or Orca itself.

## What is in scope

This repository packages Orca. It contains a `Dockerfile`, an entrypoint, two helper
scripts, and compose files. In scope:

- The `Dockerfile` — for example a way to make the image build something other than
  what it claims to, or to run as root.
- `entrypoint.sh` — for example argument injection through an environment variable,
  or a configuration that silently exposes the runtime.
- `scripts/*.sh` — for example a healthcheck or pairing helper that can be made to
  leak the pairing credential.
- The compose files — for example a default that exposes the runtime to the network
  when the documentation says it does not.
- Anything that lets a client of this image reach beyond the privileges the
  documentation claims for it.

## What is out of scope

**Report these upstream**, at [stablyai/orca](https://github.com/stablyai/orca):

- Anything in Orca itself: the runtime, the pairing protocol, the agent harnesses,
  the web client.
- Vulnerabilities in Chromium, Electron or the distribution packages inside the
  image. Those are the vendors' to fix; this repository only consumes them.

## Known and accepted

These are documented tradeoffs, not oversights. A report about one of them is
welcome if you think the reasoning is wrong, but please read the reasoning first.

### Chromium's sandbox is disabled by default

`ORCA_NO_SANDBOX=true` adds `--no-sandbox`. Chromium's SUID helper needs
`CAP_SYS_ADMIN` to create its namespaces, which a default container does not have,
and the user-namespace sandbox is blocked by Docker's seccomp profile and by
Ubuntu's AppArmor restriction. There is no configuration that both keeps the default
container privileges and runs a sandboxed renderer.

The container still runs as an unprivileged user with `cap_drop: ALL` and
`no-new-privileges`. Full reasoning, and how to opt into the real sandbox at the
cost of granting `SYS_ADMIN`:
[Security](docs/security.md#about-no-sandbox).

### Secrets are stored unencrypted

There is no unlocked D-Bus session keyring in a headless container, so Orca stores
its secrets in the state directory in plaintext and says so in the log. Anyone who
can read that volume or directory can read them. Restrict access to it:
[Security](docs/security.md#secrets-are-stored-unencrypted).

### The pairing URL is a credential

It carries a device token and E2EE material. It is printed to the container log on
purpose — that is the only way to retrieve it, because Orca offers no CLI command to
mint one against a running runtime. Treat the log as sensitive, and revoke grants you
no longer need.

## Supported versions

Only the most recent published image is supported. It tracks the Orca release named
in the README badge and in `ORCA_VERSION`.

Fixes are published as a new image tag. Older tags are not patched.

## How this project scans itself

Every published image is scanned with [Trivy](https://trivy.dev) for `CRITICAL` and
`HIGH` findings with a fix available. Results land in this repository's **Security**
tab under code scanning alerts.

The scan does not fail the build. The image carries roughly 470 MB of distribution
packages and most findings have no upstream fix; failing on them would block every
build on something nobody can act on. Triage happens in the Security tab instead.

## Response

This is a small project maintained in spare time. There is no formal SLA. Expect an
acknowledgement within about a week, and please do not disclose publicly until a fix
has been published as a new image tag.
