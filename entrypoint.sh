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

for pair in "ORCA_PORT:${ORCA_PORT}" "ORCA_HOST_PORT:${ORCA_HOST_PORT}"; do
  name="${pair%%:*}"; value="${pair#*:}"
  case "$value" in
    ''|*[!0-9]*) fail "${name} must be numeric (got '${value}')" ;;
  esac
  if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
    fail "${name} must be between 1 and 65535 (got '${value}')"
  fi
done

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

# Orca stores its state under $HOME/.config and creates worktree checkouts under
# $HOME/orca/workspaces. Both must be writable and mounted, or work is lost.
for dir in "${HOME:-/home/orca}/.config" "${HOME:-/home/orca}/orca/workspaces" "${ORCA_PROJECTS:-}"; do
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

# exec: Orca becomes PID 1 and receives SIGTERM/SIGINT directly.
exec "$ORCA_LAUNCHER" "${args[@]}"
