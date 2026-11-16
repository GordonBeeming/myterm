# Basic connection routing experiment

This throwaway prototype belongs to [Validate connection routing and deployment enrollment](https://github.com/GordonBeeming/myterm/issues/161). Gordon accepted the bounded basic routing direction in [the resolution](https://github.com/GordonBeeming/myterm/issues/161#issuecomment-6915690907). The remaining native integration and enrollment work is retained in separate tickets; Azure VM scale-set validation is deferred until basic connections work.

## Confirmed through live discussion

Automatic selects the first permitted route that completes server authentication and is ready to attach. It keeps that route until failure, a network change or a Settings refresh. A successful route does not trigger ongoing speed comparisons.

Direct only permits same-machine local access and configured direct addresses. It never falls back to relay. Relay only requires relay even when the server is on the same Mac.

While a terminal is actively in use, target detection of a silent connection failure within about five seconds. Lightweight checks may use the selected connection; they do not authorize probing competing routes while that connection works. This is a detection target, not a guarantee that reattachment finishes within five seconds.

## Run the socket experiment

From the repository root, with Python 3.11+ and OpenSSL 3 on PATH:

```sh
python3 docs/wayfind/125/connection-routing/probe.py \
  --output docs/wayfind/125/connection-routing/evidence/loopback.json
```

The probe generates disposable mutual-TLS certificates in an automatically removed temporary directory, binds loopback TCP ports and a Unix socket, starts its own shell, executes the checks and shuts down its resources. It never reads account credentials, connects to a shared relay or changes the app's settings. The selector instance represents one client and one server; its cache is scoped to that instance. A caller must request a refresh when returning to a previously seen network context; a different cache key alone is not network-change detection.

Local and direct candidates use real TLS 1.3 sockets. The relay candidate traverses an opaque loopback TCP forwarder to the same TLS server. Readiness includes a successful attach response after peer verification. Configurable fixture delays make the selection order repeatable; relay delay is additional to its backend's attach delay. On a selected direct-route failure, the client reconnects through the Unix socket. The fixture's shell outlives the client sockets, and its PID and incrementing counter confirm that the same process answers before and after. The shell uses pipes, not a PTY. No write is in flight at disconnection, so input retry/deduplication and interrupted output are untested.

The recorded checks cover selection, remembered-route reuse, refresh, a changed network-context identifier, explicit mode restrictions, relay disabled, untrusted server certificates, wrong identity pins, missing/untrusted client certificates, a fast unauthenticated race candidate, fixture viewer input rejection, a bounded readiness timeout and eventual server-side loser/handler cleanup. Cleanup can wait for the injected delay to finish; prompt client-side cancellation is unmeasured. The network-context change is injected; no actual Wi-Fi or VPN change is performed. The 80 ms negative-case deadline and the ordinary 700 ms route-attempt deadline are fixture settings, not proposed product budgets. These measurements include intentional delays and cannot establish remote-network latency targets. The retained-socket RPC check counts new route attempts during one request; no long-duration idle or background-polling measurement is claimed.

The active-connection watchdog uses a one-second fixture cadence and a five-second absolute deadline from its last confirmed health response. The server suppresses subsequent health responses for that connection while leaving TCP/TLS open. Two healthy replies and the suppressed-response interval produce no new route attempts from this fixture watchdog. The harness invokes selection after the timeout, excludes the failed route and reconnects; a production automatic recovery coordinator is not implemented. The original shell counter advances to three. This exercises an application-response stall on one Mac, not packet loss injected into Wi-Fi, a VPN or a hosted relay. The test permits 500 ms of scheduler overshoot when checking the five-second target and records the actual elapsed time; a heavily loaded machine can fail this timing check. Requests are serialized in the fixture; production health/application multiplexing and traffic-based liveness updates remain unimplemented. The one-second cadence is an experimental setting, not a settled battery or traffic budget.

## Interactive walkthrough

Open `walkthrough.html` directly. It contains an in-memory routing model, guided scenarios and a snapshot of the socket evidence. Buttons do not connect to a MyTerm server. The visible fixture times and process description are illustrative; the measured results are a separate table.

After rerunning the probe, update the embedded evidence with this command:

```sh
python3 - <<'PY'
import json
from pathlib import Path
p = Path('docs/wayfind/125/connection-routing')
page = p / 'walkthrough.html'
text = page.read_text()
start = '<script id="measurements" type="application/json">'
before, rest = text.split(start, 1)
_, after = rest.split('</script>', 1)
data = json.loads((p / 'evidence/loopback.json').read_text())
assert data['completed'] and all(c['passed'] for c in data['checks'])
page.write_text(before + start + json.dumps(data).replace('<', '\\u003c') + '</script>' + after)
PY
```

## Acceptance still outstanding

This experiment supplies local routing evidence. The selected Rust server, Swift client integration, native process authentication for same-machine discovery, encrypted directory configuration, cached account trust, real PTY/SwiftTerm restoration, durable control leases, layout synchronization and a hosted relay are not exercised here. The TLS trust roots and authorized client certificates are fixture bootstrap, not the selected production account-trust protocol. Control ownership is server memory with a fixed initial controller; control handoff is not implemented.

The closed routing decision preserves its remaining acceptance gaps in [Implement native Mac connection routing and session recovery](https://github.com/GordonBeeming/myterm/issues/192), [Validate deployment credential expiry, revocation and offline enrollment](https://github.com/GordonBeeming/myterm/issues/193) and [Validate Azure VM scale-set enrollment after basic native connections work](https://github.com/GordonBeeming/myterm/issues/194). Deployment credential issuance, expiry, overlap, revocation and enrollment remain untested here. Acceptance of the bounded routing direction does not establish production readiness. Do not replace the existing quiet native connection/close design with this diagnostic walkthrough.

Next, schedule and implement the native transport slice alongside the existing security and terminal workstreams. Credential validation remains a separate unanswered question; Azure execution follows working basics. A lost connection can fail immediately; the agreed five-second target covers silent-failure detection while actively using a terminal. Background/mobile suspension behavior and end-to-end reattachment latency remain unverified. No periodic competing-route probing is proposed.
