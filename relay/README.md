# MyTerm Relay

A small Cloudflare Workers + Durable Objects service that lets a phone or iPad reach a Mac's MyTerm
host when the two are not on the same local network.

## What it is

MyTerm Relay is a rendezvous pipe, not a proxy that understands the protocol running through it. A
Mac keeps one outbound WebSocket open to the relay under a rendezvous id. A device connects to the
relay naming that same id. The relay joins the two connections and forwards binary WebSocket frames
between them, byte for byte, in order.

There is one Durable Object instance per rendezvous id, so each pairing gets its own isolated state:
its own host key, its own list of in-flight sessions, its own counters. Nothing about one rendezvous
id is visible to another.

## What it can and cannot see

The bytes that cross the relay are an end-to-end TLS session between the Mac and the device,
established over the relay's pipe with a pre-shared key the relay never holds. The relay is not a
party to that session, so it cannot see plaintext of any kind: workspace names, screen contents,
keystrokes, or the pairing token.

The relay does see, because it must in order to forward frames:

- That a connection exists between a given rendezvous id and a device, and for how long.
- The size of each frame and its timing.
- The rendezvous id and the host key, both opaque random strings the Mac generates. The key is
  stored only to reject a different Mac claiming the same id.

The relay logs nothing about payloads. Its only bookkeeping is a per-object count of sessions.

## Running locally

```
npm install
npm run dev
```

This starts `wrangler dev`, serving the Worker on this machine with local SQLite-backed Durable
Object storage. No Cloudflare account is needed for that.

```
npm test
```

This spawns `wrangler dev` itself and drives the whole protocol over real WebSocket connections:
registration, byte-for-byte forwarding both ways, buffered-frame flushing, close codes, and the key
check. The Swift ends are tested against the same local Worker by `RelayEndToEndTests` in the main
package (`make relay-test` at the repository root runs both).

## Deploying

```
wrangler login
npm run deploy
```

`wrangler login` is once per machine. `npm run deploy` publishes the Worker and its Durable Object
class as `myterm-relay`. Put the Worker's origin (for example
`https://myterm-relay.<account>.workers.dev`) into **Settings → Devices → Relay address** in MyTerm
on the Mac and turn on **Reach this Mac through the relay**. Devices linked after that carry the
relay in their pairing code.

Running this is owning a service: uptime, an abuse path, rate limits per rendezvous id, and a
privacy statement that says exactly what the section above says.

## Protocol (v1)

All endpoints live under the Worker's origin. Control messages between the relay and the host are
JSON text frames. All session traffic is binary frames, forwarded verbatim and in order. Text frames
on a session socket are ignored.

A rendezvous id and a host key are opaque strings of 16 to 128 characters, `[A-Za-z0-9_-]` only. A
malformed id or key is rejected with `400` before it reaches the Durable Object.

### Endpoints

- `GET /` returns `200` with the text `myterm relay`. `GET /v1/health` returns `200` with `{"ok":true}`.
- `GET /v1/host/{id}`: WebSocket upgrade with header `X-MyTerm-Host-Key: <key>`. This is the
  **control socket**, held open for as long as the Mac wants to be reachable at `{id}`.
  - The object for `{id}` stores the first key it ever sees. A later connection for the same id
    with a different key is rejected with `403` and never upgraded.
  - If a control socket is already connected for this id, it is closed with code `4001`, reason
    `replaced`, before the new one is accepted, so a Mac can always take back its own id.
  - The relay sends the host `{"type":"open","session":"<sid>"}` each time a device wants a
    session; `<sid>` is 32 hexadecimal characters. The host may send `{"type":"ping"}` and gets
    `{"type":"pong"}`. Any other host message is ignored.
- `GET /v1/host/{id}/session/{sid}`: WebSocket upgrade with the same header and check. This is a
  **host session socket**. `{sid}` must be pending for this id, or the upgrade is rejected with
  `404`. Once accepted it is joined to the waiting device socket, and device frames that arrived
  first (buffered, up to 64 KiB) are flushed to the host in their original order.
- `GET /v1/device/{id}`: WebSocket upgrade, no authentication.
  - No control socket connected: the device is accepted, then closed with `4004`, `host offline`.
  - Sixteen or more sessions pending or open: closed with `4029`, `too many sessions`.
  - Otherwise the relay makes a session id, tells the host, and waits up to 10 seconds for the
    host session socket. If none arrives the device is closed with `4008`, `host did not answer`.
  - Once joined, binary frames are piped both ways until either side closes.

### Closing

When either side of a joined session closes, the other is closed with code `1000`, reason
`peer closed`. When a control socket closes, every pending session for that id is closed with
`4004`, `host offline`. When a control socket is replaced, every pending session is announced again
to the new socket with a fresh `open` message, and keeps whatever remains of its ten seconds: a
device that arrived while the Mac was reconnecting is handed to the Mac that came back.

### Limits

- A frame larger than 1 MiB closes that socket with `1009`.
- Buffered device frames are capped at 64 KiB per session; exceeding it closes the device with `1009`.
- At most 16 sessions, pending plus open, per rendezvous id.

### A runtime note

A binary message arrives in the Durable Object as an ArrayBuffer, a typed-array view, or a Blob,
depending on the runtime and compatibility flags, and only a plain ArrayBuffer is forwarded intact.
The Worker normalises every frame to an ArrayBuffer and handles each side's frames on one ordered
chain, so a slow Blob read can never reorder a TLS stream.
