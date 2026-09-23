# syntax=docker/dockerfile:1
#
# Orca Headless Docker — run `orca serve` on a Linux host with no desktop session.
#
# Upstream reference: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md
#
# Design notes (all of these are deliberate — see the README for the reasoning):
#   * Ubuntu 24.04 is the base because it is on Orca's supported matrix and the
#     upstream guide publishes the exact package list for it (the `t64` names).
#   * The AppImage is downloaded and extracted in a separate stage, so the ~190 MB
#     AppImage never lands in a layer of the final image and FUSE is never needed.
#   * The container runs as an unprivileged user, never as root.

ARG UBUNTU_VERSION=24.04


# ---------------------------------------------------------------------------
# Stage 1 — download and extract the Orca AppImage
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS fetch

# Pin a concrete release for reproducible builds; `latest` is accepted but not
# recommended. CI overrides this with the version it was told to publish.
ARG ORCA_VERSION=v1.4.206
# Provided automatically by BuildKit for multi-platform builds.
ARG TARGETARCH

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl file \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/orca

RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) asset="orca-linux.AppImage" ;; \
      arm64) asset="orca-linux-arm64.AppImage" ;; \
      *) echo "FATAL: unsupported TARGETARCH '${TARGETARCH:-}'" >&2; exit 1 ;; \
    esac; \
    if [ "${ORCA_VERSION}" = "latest" ]; then \
      url="https://github.com/stablyai/orca/releases/latest/download/${asset}"; \
    else \
      url="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/${asset}"; \
    fi; \
    echo "Downloading ${url}"; \
    curl -fL --retry 5 --retry-delay 3 --retry-all-errors -o /opt/orca/orca.AppImage "${url}"; \
    chmod 0755 /opt/orca/orca.AppImage; \
    LC_ALL=C file /opt/orca/orca.AppImage | grep -q 'ELF .* executable'; \
    \
    # Docker normally has no FUSE device. `--appimage-extract` reads the file
    # directly, so it needs neither FUSE nor a privileged container.
    /opt/orca/orca.AppImage --appimage-extract; \
    test -x /opt/orca/squashfs-root/AppRun; \
    mv /opt/orca/squashfs-root /opt/orca/app; \
    rm -f /opt/orca/orca.AppImage; \
    printf '%s\n' "${ORCA_VERSION}" > /opt/orca/VERSION; \
    \
    # `--appimage-extract` writes squashfs-root as drwx------ owned by the
    # extracting user. Without this, the runtime user cannot traverse it and the
    # container dies before Electron starts.
    chmod -R a+rX /opt/orca/app


# ---------------------------------------------------------------------------
# Stage 2 — runtime image
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG PUID=1000
ARG PGID=1000
ARG ORCA_USER=orca
# Space-separated extra apt packages (for example agent CLIs' system deps).
ARG ORCA_EXTRA_PACKAGES=""

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    # VPS/container hosts have no GPU; force software GL or Electron aborts.
    LIBGL_ALWAYS_SOFTWARE=1 \
    # Set explicitly so it survives a `user:` override in compose.
    HOME=/home/${ORCA_USER} \
    # `orca serve` registers the CLI into $HOME/.local/bin, which moves when
    # HOME is overridden. /opt/orca/bin is a fixed entry point that always
    # resolves, so `orca-ide` works regardless of HOME.
    PATH=/opt/orca/bin:/home/${ORCA_USER}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    ORCA_INSTALL_DIR=/opt/orca \
    ORCA_APP_DIR=/opt/orca/app \
    ORCA_LOG_FILE=/tmp/orca-serve.log \
    ORCA_PORT=6768 \
    ORCA_PAIRING_ADDRESS=127.0.0.1 \
    ORCA_JSON=true \
    ORCA_NO_SANDBOX=true

# Package list from Orca's official headless guide (Ubuntu 24.04 / Debian 13+
# naming, where the 64-bit time_t transition added the `t64` suffix), plus
# netcat-openbsd for the healthcheck.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      file \
      git \
      jq \
      netcat-openbsd \
      xvfb \
      zlib1g-dev \
      libgtk-3-0t64 \
      libnss3 \
      libatk1.0-0t64 \
      libatk-bridge2.0-0t64 \
      libgbm1 \
      libasound2t64 \
      libxtst6 \
      libcups2t64 \
      libdrm2 \
      libxkbcommon0 \
      libpango-1.0-0 \
      libcairo2 \
      libatspi2.0-0t64 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxrandr2 \
      libxrender1 \
      libx11-xcb1 \
      libxcb-dri3-0 \
      libxss1 \
      ${ORCA_EXTRA_PACKAGES} \
 && rm -rf /var/lib/apt/lists/*

# Create the unprivileged service account. UID/GID are >= 1000 by construction:
# the ubuntu:24.04 base already owns 1000 for its `ubuntu` account (which is also
# a member of the sudo group), so reclaim those IDs when they collide.
RUN set -eux; \
    case "${PUID}" in ''|*[!0-9]*) echo "FATAL: PUID must be numeric" >&2; exit 1 ;; esac; \
    case "${PGID}" in ''|*[!0-9]*) echo "FATAL: PGID must be numeric" >&2; exit 1 ;; esac; \
    if [ "${PUID}" -lt 1000 ] || [ "${PGID}" -lt 1000 ]; then \
      echo "FATAL: PUID and PGID must be >= 1000 (got ${PUID}:${PGID})" >&2; exit 1; \
    fi; \
    reclaimed=""; \
    for id_name in "$(getent passwd "${PUID}" | cut -d: -f1)" "$(getent group "${PGID}" | cut -d: -f1)"; do \
      if [ -z "${id_name}" ] || [ "${id_name}" = "${ORCA_USER}" ]; then continue; fi; \
      case " ${reclaimed} " in *" ${id_name} "*) continue ;; esac; \
      reclaimed="${reclaimed} ${id_name}"; \
      echo "Reclaiming UID/GID ${PUID}:${PGID} from '${id_name}'"; \
      userdel -r "${id_name}" 2>/dev/null || groupdel "${id_name}" 2>/dev/null || true; \
    done; \
    groupadd --gid "${PGID}" "${ORCA_USER}"; \
    useradd --uid "${PUID}" --gid "${PGID}" \
            --create-home --shell /bin/bash --no-log-init "${ORCA_USER}"; \
    # These directories are mounted as named volumes in compose. Creating them
    # here with the right ownership matters: Docker seeds a fresh named volume
    # from the image, so a directory that does not exist would be created
    # root-owned and the unprivileged user could not write to it. `install -d`
    # applies -o/-g only to the paths it is given, so the parent has to be
    # listed explicitly — otherwise /home/orca/orca ends up root-owned.
    install -d -o "${ORCA_USER}" -g "${PGID}" -m 0755 \
      "/home/${ORCA_USER}/.config" \
      "/home/${ORCA_USER}/orca" \
      "/home/${ORCA_USER}/orca/workspaces" \
      "/home/${ORCA_USER}/projects"; \
    id "${ORCA_USER}"

COPY --from=fetch /opt/orca/app /opt/orca/app
COPY --from=fetch /opt/orca/VERSION /opt/orca/VERSION

COPY entrypoint.sh /usr/local/bin/orca-entrypoint
COPY scripts/healthcheck.sh /usr/local/bin/orca-healthcheck

# /opt/orca/bin is a stable CLI entry point, independent of HOME: `orca serve`
# registers the CLI into $HOME/.local/bin, which moves when HOME is overridden.
# Deliberately named `orca-ide` and not `orca` — upstream reserves the bare name
# for the GNOME screen reader.
RUN chmod 0755 /usr/local/bin/orca-entrypoint /usr/local/bin/orca-healthcheck \
 && mkdir -p /opt/orca/bin \
 && ln -sfn /opt/orca/app/resources/bin/orca-ide /opt/orca/bin/orca-ide \
 && /opt/orca/bin/orca-ide --version

USER ${ORCA_USER}
WORKDIR /home/${ORCA_USER}

# The pairing listener. Publish it with `ports:` in compose.
EXPOSE 6768

# Readiness is proven by Orca's own versioned contract on stdout, not by a bare
# TCP connect. `--start-period` failures do not count towards `--retries`, which
# matters because first boot may migrate persisted state. The 15s interval means
# the first probe lands well inside the ~5s real startup time, so `depends_on:
# condition: service_healthy` does not wait on a 30s default tick.
HEALTHCHECK --interval=15s --timeout=10s --start-period=90s --retries=3 \
  CMD ["/usr/local/bin/orca-healthcheck"]

ENTRYPOINT ["/usr/local/bin/orca-entrypoint"]
