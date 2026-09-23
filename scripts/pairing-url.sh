#!/bin/sh
#
# Print the pairing information for a running Orca headless server.
#
# Run it inside the container:
#   docker compose exec orca orca-pairing-url
#   podman exec orca /usr/local/bin/orca-pairing-url
#
# Or read the same values straight from the logs:
#   docker compose logs orca | grep -o 'orca://pair?code=[^"]*' | tail -1
#
# Orca mints the pairing link at startup and writes it to its readiness output.
# There is no CLI command to mint a new one against a running runtime, so this
# reads the log the entrypoint mirrors.

set -eu

log_file="${ORCA_LOG_FILE:-/tmp/orca-serve.log}"

if [ ! -s "$log_file" ]; then
  echo "No Orca output captured in ${log_file} yet. Give it a few seconds." >&2
  exit 1
fi

# JSON mode:  "url":"orca://pair?code=..."
# Text mode:  Pairing URL: orca://pair?code=...
pairing=$(grep -o 'orca://pair?code=[A-Za-z0-9_-]*' "$log_file" 2>/dev/null | tail -1 || true)

# JSON mode:  "webClientUrl":"http://..."
# Text mode:  Web client URL: http://...
web=$(grep -oE '"(webClientUrl|Web client URL)"?[: ]*"?(https?://[^",]+)' "$log_file" 2>/dev/null |
  tail -1 | grep -oE 'https?://[^",]+' || true)
[ -n "$web" ] || web=$(grep -oE 'Web client URL: https?://[^ ]+' "$log_file" 2>/dev/null |
  tail -1 | sed 's/^Web client URL: //' || true)

bound=$(grep -oE '"boundEndpoint":"[^"]*"' "$log_file" 2>/dev/null | tail -1 | cut -d'"' -f4 || true)
advertised=$(grep -oE '"advertisedEndpoint":"[^"]*"' "$log_file" 2>/dev/null | tail -1 | cut -d'"' -f4 || true)
[ -n "$advertised" ] || advertised=$(grep -oE 'Advertised endpoint: [^ ]+' "$log_file" 2>/dev/null |
  tail -1 | sed 's/^Advertised endpoint: //' || true)

scope=$(printf '%s' "$pairing" | sed 's|.*code=||' | base64 -d 2>/dev/null |
  grep -oE '"scope":"[^"]*"' | cut -d'"' -f4 || true)

if [ -z "$pairing" ] && [ -z "$web" ]; then
  echo "Orca has not reported a pairing link yet." >&2
  echo "Check the log for a pairing reason:" >&2
  echo "  grep -o '\"pairing\":{[^}]*}' ${log_file}" >&2
  exit 1
fi

echo "Pairing scope : ${scope:-unknown}"
[ -n "$bound" ] && echo "Bound         : ${bound}"
[ -n "$advertised" ] && echo "Advertised    : ${advertised}"
echo
if [ -n "$pairing" ]; then
  echo "Pairing URL (paste into Orca: Settings -> Remote Orca Servers -> Add Server):"
  echo
  echo "  ${pairing}"
  echo
fi
if [ -n "$web" ]; then
  echo "Browser URL (open it directly, the pairing code is embedded):"
  echo
  echo "  ${web}"
  echo
fi

if [ "${scope:-}" = "mobile" ]; then
  echo "This is a MOBILE-scoped link: it pairs the Orca Mobile app and cannot be"
  echo "used by a desktop client. Remove --mobile-pairing from ORCA_EXTRA_ARGS and"
  echo "restart to get a runtime link instead."
fi
