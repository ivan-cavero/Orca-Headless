#!/usr/bin/env bash
#
# Entrypoint for the Orca headless server container.
#
# Responsibilities:
#   * translate the ORCA_* environment variables into `orca serve` arguments;
#   * make the advertised port explicit, so a published host port that differs
#     from the container port does not produce an unreachable pairing URL;
#   * refuse configurations that cannot work (wildcard pairing address);
#   * warn about configurations that will confuse the operator (loopback pairing
#     address, unwritable state / workspaces / projects directories);
#   * mirror stdout/stderr into a log file so the healthcheck can verify Orca's
#     readiness contract;
#   * exec the server so it becomes PID 1 and receives signals directly.
#
# Reference: https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md

set -euo pipefail

ORCA_APP_DIR="${ORCA_APP_DIR:-/opt/orca/app}"
ORCA_LAUNCHER="${ORCA_APP_DIR}/AppRun"
ORCA_LOG_FILE="${ORCA_LOG_FILE:-/tmp/orca-serve.log}"
ORCA_PORT="${ORCA_PORT:-6768}"
# Port published on the host. Defaults to the container port, which is what the
# bundled compose file publishes.
ORCA_HOST_PORT="${ORCA_HOST_PORT:-$ORCA_PORT}"
ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-127.0.0.1}"
ORCA_JSON="${ORCA_JSON:-true}"
ORCA_NO_SANDBOX="${ORCA_NO_SANDBOX:-true}"

log() { printf '[entrypoint] %s\n' "$*" >&2; }
fail() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

# --- sanity checks ---------------------------------------------------------

[ -x "$ORCA_LAUNCHER" ] || fail "Orca launcher not found or not executable: ${ORCA_LAUNCHER}"

# The home directory has to be usable before anything else is worth checking.
#
# If it is not traversable, the per-directory checks below see nothing, pass, and
# Orca then dies inside Electron with "Failed to get 'userData' path" and exit 132 —
# an error that names no permission and points nowhere near the cause.
#
# It happens after changing userns_mode, PUID/PGID or user: on an existing volume:
# a named volume keeps the ownership of whatever UID mapping created it, so the new
# mapping finds it owned by a stranger.
orca_home="${HOME:-/home/orca}"
if [ ! -d "$orca_home" ]; then
  fail "the container's home directory '${orca_home}' does not exist."
elif [ ! -x "$orca_home" ] || [ ! -w "$orca_home" ]; then
  home_owner="$(stat -c '%u' "$orca_home" 2>/dev/null || echo '?')"
  home_mode="$(stat -c '%a' "$orca_home" 2>/dev/null || echo '?')"
  home_group="$(stat -c '%g' "$orca_home" 2>/dev/null || echo '?')"
  if [ "$home_owner" = "0" ]; then
    fail "'${orca_home}' is owned by root (mode ${home_mode}) and uid $(id -u) cannot write it.

       Orca would start and then crash with 'Failed to get userData path' and exit
       132, which says nothing about permissions. Stopping here instead.

       A root-owned home means the runtime created the directory itself, which is
       what happens when a BIND MOUNT points at a path that does not exist on the
       host yet. Docker creates it, empty and owned by root.

       Create it first, owned by the uid this container runs as:

         sudo mkdir -p /srv/orca/home/.config /srv/orca/home/.local/share \\
                      /srv/orca/home/.local/state /srv/orca/home/.cache \\
                      /srv/orca/home/orca/workspaces /srv/orca/home/projects
         sudo chown -R $(id -u):$(id -g) /srv/orca/home

       Then recreate the container. The pre-created directories matter: the bind
       hides the ones the image ships, so a deep mount such as
       /home/orca/.local/share/opencode would otherwise leave /home/orca/.local
       root-owned and break the agent that writes beside it.

       Check the host path with:
         stat -c '%u:%g %a %n' <the host directory in your compose>"
  fi
  fail "'${orca_home}' is not usable by uid $(id -u) (mode ${home_mode}, owner ${home_owner}:${home_group}).

       Orca would start and then crash with 'Failed to get userData path' and exit
       132, which says nothing about permissions. Stopping here instead.

       The owner is not root, so this is not a missing host directory. It is a
       mismatch: the container runs as uid $(id -u) and the directory belongs to
       ${home_owner}.

       That happens after changing userns_mode, PUID, PGID or user: on an existing
       volume — a named volume keeps the ownership of whatever UID mapping created
       it. Either point user: at ${home_owner}, rebuild with
       --build-arg PUID=${home_owner} --build-arg PGID=${home_group}, or recreate
       the volume:

         docker compose down
         docker volume rm <project>_orca-home
         docker compose up -d"
fi

for pair in "ORCA_PORT:${ORCA_PORT}" "ORCA_HOST_PORT:${ORCA_HOST_PORT}"; do
  name="${pair%%:*}"; value="${pair#*:}"
  case "$value" in
    ''|*[!0-9]*) fail "${name} must be numeric (got '${value}')" ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    fail "${name} must be between 1 and 65535 (got '${value}')"
  fi
done

# Agents installed under the home directory are only found if their bin directories
# are on PATH. The image's PATH names /home/orca/.local/bin, which is wrong the
# moment HOME is overridden — and overriding HOME is exactly what ORCA_HOME_DIR
# does. Without this, an agent sitting in $HOME/.bun/bin is invisible to Orca and
# the user has to reconstruct PATH by hand to work around it.
#
# Prepending here fixes detection for Orca itself. `docker compose exec` still sees
# the image's PATH, so override PATH in compose too if you want it there.
for agent_bin in "${orca_home}/.local/bin" "${orca_home}/.bun/bin" "${orca_home}/.grok/bin"; do
  case ":${PATH}:" in
    *":${agent_bin}:"*) ;;
    *) PATH="${agent_bin}:${PATH}" ;;
  esac
done

# Agents installed through a Node version manager sit on a version-specific path,
# and they shell out to `node`, which the image does not ship unless NODE_VERSION was
# set at build time. Picking up whatever is there lets a host-managed agent work
# without a rebuild.
#
# Two layouts exist in the wild and both are checked: nvm's default
# ($HOME/.nvm/versions/node/<v>/bin) and the one that puts the versions under the
# data directory ($HOME/.local/share/nvm/<v>/bin). Missing the second is how a real
# `pi` install kept failing with "/usr/bin/env: 'node': No such file or directory".
for node_bin in \
  "${orca_home}"/.nvm/versions/node/*/bin \
  "${orca_home}"/.local/share/nvm/*/bin; do
  if [ -d "${node_bin}" ]; then
    case ":${PATH}:" in
      *":${node_bin}:"*) ;;
      *) PATH="${node_bin}:${PATH}" ;;
    esac
  fi
done
export PATH

# Orca advertises this address to clients; it does not change the bind address.
case "$ORCA_PAIRING_ADDRESS" in
  ''|'*'|'0.0.0.0'|'::')
    fail "ORCA_PAIRING_ADDRESS='${ORCA_PAIRING_ADDRESS}' cannot be advertised.
       Set it to the address a client uses to reach this host: the server's
       LAN IP, DNS name, Tailscale address, or a full reverse-proxy URL." ;;
  127.0.0.1|localhost|'::1')
    log "WARNING: ORCA_PAIRING_ADDRESS is '${ORCA_PAIRING_ADDRESS}'."
    log "         The printed pairing URL will only work from inside this"
    log "         container. Set ORCA_PAIRING_ADDRESS to the address clients"
    log "         use to reach this host before pairing a remote client." ;;
esac

# Orca combines the advertised host with the port it actually *bound* when the
# address carries no port. Inside the container that is ORCA_PORT, so publishing
# a different host port silently produces a pairing URL nobody can reach. Make
# the host port explicit whenever the address is a bare host or bare IPv6.
# Order matters: the IPv6 patterns must be tested before the generic "host:port".
case "$ORCA_PAIRING_ADDRESS" in
  *://*)   : ;;                                                                   # full URL: the user owns the port
  \[*\]:*) : ;;                                                                   # [ipv6]:port already explicit
  \[*\]*)  ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS}:${ORCA_HOST_PORT}" ;;     # bare [ipv6]
  *:*:*)   : ;;                                                                   # bare IPv6, unbracketed
  *:*)     : ;;                                                                   # host:port already explicit
  *)       ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS}:${ORCA_HOST_PORT}" ;;
esac

# Orca stores its state under $HOME/.config, creates worktree checkouts under
# $HOME/orca/workspaces, and imports projects from $HOME/projects. All three must
# be writable, or work is lost. These are container paths — the host-side
# ORCA_PROJECTS value is a mount source and says nothing about the container.
for dir in "${HOME:-/home/orca}/.config" "${HOME:-/home/orca}/orca/workspaces" "${HOME:-/home/orca}/projects"; do
  [ -n "$dir" ] || continue
  if [ -d "$dir" ] && [ ! -w "$dir" ]; then
    log "WARNING: '${dir}' exists but is not writable by uid $(id -u)."
    log "         Orca cannot persist state or create worktrees there."
    log "         Rebuild with a matching --build-arg PUID/PGID, chown the host"
    log "         directory to $(id -u):$(id -g), or (rootless Podman) add"
    log "         userns_mode: keep-id. See 'Paths' in the README."
  fi
done

# --- build the command -----------------------------------------------------

# Chromium switches must precede the `serve` subcommand, exactly as documented.
args=()
if [ "$ORCA_NO_SANDBOX" = "true" ]; then
  args+=(--no-sandbox)
fi

args+=(serve --port "$ORCA_PORT" --pairing-address "$ORCA_PAIRING_ADDRESS")

if [ "$ORCA_JSON" = "true" ]; then
  args+=(--json)
fi

# Escape hatch for flags this image does not model. Word-split on purpose.
if [ -n "${ORCA_EXTRA_ARGS:-}" ]; then
  # shellcheck disable=SC2206
  args+=(${ORCA_EXTRA_ARGS})
fi

# --- tee stdout/stderr into a file the healthcheck can read ----------------

: >"$ORCA_LOG_FILE" 2>/dev/null || fail "cannot write log file ${ORCA_LOG_FILE}"
exec > >(tee -a "$ORCA_LOG_FILE")
exec 2> >(tee -a "$ORCA_LOG_FILE" >&2)

log "starting Orca server"
log "  launcher         : ${ORCA_LAUNCHER}"
log "  listen port      : ${ORCA_PORT}"
log "  published port   : ${ORCA_HOST_PORT}"
log "  pairing address  : ${ORCA_PAIRING_ADDRESS}"
log "  json contract    : ${ORCA_JSON}"
if [ "$ORCA_NO_SANDBOX" = "true" ]; then
  log "  sandbox          : disabled (ORCA_NO_SANDBOX=true)"
else
  log "  sandbox          : enabled (needs cap_add: [SYS_ADMIN] on the container)"
fi
log "  expected noise   : Chromium logs a few errors below that are expected and"
log "                     harmless. A container has no system D-Bus, no session"
log "                     D-Bus and no keyring, and Orca needs none of them to"
log "                     serve. The line that matters is the readiness contract;"
log "                     run 'orca-pairing-url' to print the link."

# exec: Orca becomes PID 1 and receives SIGTERM/SIGINT directly.
exec "$ORCA_LAUNCHER" "${args[@]}"
