# Pairing and connecting

## Getting the pairing link

Orca mints the pairing link at startup and writes it to its readiness output.
**There is no CLI command to mint one against a running runtime** — the log is the
only source, so this image ships a helper that reads it:

```bash
docker compose exec orca orca-pairing-url
```

```
Pairing scope : runtime
Bound         : ws://0.0.0.0:6768
Advertised    : ws://10.0.0.5:6768

Pairing URL (paste into Orca: Settings -> Remote Orca Servers -> Add Server):

  orca://pair?code=eyJ2IjoyLCJlbmRwb2ludCI6IndzOi8vMTAuMC4wLjU6Njc2OCIs...

Browser URL (open it directly, the pairing code is embedded):

  http://10.0.0.5:6768/web-index.html#pairing=orca%3A%2F%2Fpair%3Fcode%3D...
```

Or read it straight from the logs, which is the same data:

```bash
docker compose logs orca | grep -o 'orca://pair?code=[^"]*' | tail -1
```

The helper also reports the scope, and says so explicitly when the link is
mobile-scoped — that is the case where copying it into a desktop client looks like it
worked and then silently fails.

### The link is stable

It is derived from device credentials stored in the state directory, so it is
**byte-identical** across `docker compose restart` and across a full `down` + `up`. A
client that already paired stays paired through a redeploy, and you can re-read the
same link any time.

It changes only when the state is destroyed (`docker compose down -v`) or when you
revoke the grant. After either, clients must pair again.

If you need a fresh link without losing state, revoke the old grant from the client's
**Shared Server Access** list and restart the container.

### If there is no link

The runtime is probably still starting — wait a few seconds. If it keeps reporting
none, pairing failed and the log carries a stable reason:

```bash
docker compose logs orca | grep -o '"pairing":{[^}]*}'
```

| Reason | Meaning |
| --- | --- |
| `disabled_by_operator` | You passed `--no-pairing`. |
| `websocket_unavailable` | The listener did not come up. |
| `device_registry_unavailable` | The persisted device registry could not be read. |
| `e2ee_key_unavailable` | The encryption material could not be created. |
| `invalid_advertised_endpoint` | `ORCA_PAIRING_ADDRESS` was a wildcard or otherwise unusable. |

---

## Connecting a client

- **Desktop app** — **Settings → Remote Orca Servers → Add Server**, paste the
  pairing URL.
- **Browser** — open the `Browser URL` instead; the pairing code is already embedded
  in the fragment, so it connects without any copy-paste.
- **Mobile** — see below. It needs a different kind of link.

The pairing URL contains a device credential and E2EE material. Treat it like a
password, and revoke grants you no longer need from **Shared Server Access** on the
server side.

### Mobile pairing is a separate mode

`--mobile-pairing` does not add a second link — it **replaces** the runtime link with
a mobile-scoped one. Upstream is explicit: it prints a mobile-scoped QR/link *"instead
of the default runtime-environment pairing link"*.

```bash
# in .env
ORCA_EXTRA_ARGS=--mobile-pairing
ORCA_JSON=false          # required for the scannable QR; JSON mode reports qr:null
```

Restart, then scan the QR from the logs with the Orca Mobile app's **Pair** flow, or
copy the link that `orca-pairing-url` prints.

Two consequences worth knowing, both verified:

- A **desktop client cannot use a mobile-scoped code.** `orca-ide environment add`
  accepts it but the connection fails (`runtimeId: null`).
- So you get **one or the other per run.** Leave `ORCA_EXTRA_ARGS` empty for desktop
  and browser clients; set it when you are pairing a phone.

`--no-pairing` disables pairing entirely if the runtime should not be reachable at
all.

---

## Network rules

The client dials `ORCA_PAIRING_ADDRESS`. It must be an address the client can actually
reach:

| Where the client runs | `ORCA_PAIRING_ADDRESS` |
| --- | --- |
| Same Tailscale tailnet | the server's `100.x.y.z` address |
| Same LAN | the server's LAN IP, e.g. `192.168.1.40` |
| Public DNS name | `orca.mydomain.dev` |
| Behind a TLS reverse proxy | `https://orca.example.com/runtime` |

Three things will silently break a connection:

1. **`127.0.0.1`.** The pairing URL then points at the *client's* own loopback. The
   entrypoint warns about this at startup.
2. **A firewall.** Open `ORCA_HOST_PORT` (default `6768`) for the client's source.
3. **A reverse proxy without WebSocket upgrade.** The runtime speaks WebSocket, not
   HTTP; the proxy must forward the `Upgrade`/`Connection` headers and route the
   advertised path. Advertise `https://…` when TLS terminates at the proxy — Orca
   normalises it to `wss://`.

If you published a different host port, set `ORCA_HOST_PORT` to match — the entrypoint
derives the advertised port from it. See
[Ports](configuration.md#ports).

---

## Verifying a pairing without a GUI

The image ships the `orca-ide` CLI, so you can prove the connection from the server.
`orca-ide status --environment <name>` queries the *remote* runtime over the paired
WebSocket:

```bash
docker compose exec orca sh -c '
  orca-ide environment add --name self --pairing-code "orca://pair?code=..."
  orca-ide status --environment self --json | head -30'
```

A healthy answer carries:

```json
"runtime": {
  "state": "ready",
  "reachable": true,
  "connectionState": "connected",
  "runtimeId": "93b53c1d-...",
  "appVersion": "1.4.206"
}
```

The `runtimeId` must **not** be `"local"` — that value means the CLI answered from the
local runtime instead of the remote one, which is what happens when the pairing code
is unusable (for example a mobile-scoped code used by a desktop consumer). That is
the same handshake the desktop and mobile clients perform.

You can also confirm the two transports directly from the host:

```bash
# the web client is served over plain HTTP
curl -fsS http://127.0.0.1:6768/web-index.html | grep -o '<title>[^<]*</title>'

# and the runtime speaks WebSocket
printf 'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n' \
  | nc 127.0.0.1 6768 | head -1
# expect: HTTP/1.1 101 Switching Protocols
```
