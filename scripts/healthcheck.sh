#!/bin/sh
#
# Container healthcheck for Orca Headless Docker.
#
# A bare TCP connect only proves that *something* is listening; it cannot tell a
# fully initialised Orca runtime from a process that bound its socket and then
# failed during pairing setup. So this probe verifies Orca's own readiness
# contract first, and only then confirms the listener accepts connections.
#
# With ORCA_JSON=true (the default) Orca prints one compact line:
#   {"type":"orca_server_ready","schemaVersion":1,...}
# With ORCA_JSON=false it prints the human-readable "Orca server ready" block.
# Both shapes are accepted so the probe works either way.
#
# Exit 0 = healthy, exit 1 = unhealthy.

set -eu

log_file="${ORCA_LOG_FILE:-/tmp/orca-serve.log}"
port="${ORCA_PORT:-6768}"

if [ ! -s "$log_file" ]; then
  echo "orca-healthcheck: no output captured in ${log_file} yet"
  exit 1
fi

if ! grep -qE '"type"[[:space:]]*:[[:space:]]*"orca_server_ready"' "$log_file" 2>/dev/null &&
   ! grep -q 'Orca server ready' "$log_file" 2>/dev/null; then
  echo "orca-healthcheck: Orca has not reported readiness yet"
  exit 1
fi

if ! nc -z 127.0.0.1 "$port" 2>/dev/null; then
  echo "orca-healthcheck: nothing is listening on 127.0.0.1:${port}"
  exit 1
fi

echo "orca-healthcheck: ready on port ${port}"
exit 0
