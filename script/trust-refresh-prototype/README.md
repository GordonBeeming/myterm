# Disposable TLS refresh reliability probe

This probe tests whether a failed replacement TLS connection leaves an existing
authenticated connection usable. A native Swift client and Rust server each hold
multiple BoringSSL TLS contexts. The server owns one real shell process. A Python
driver forwards opaque records and selects which connection carries each echo.

Run on macOS with Python 3.12+, Swift, Rust, CMake, clang and curl:

```sh
python3 -B script/trust-refresh-prototype/run.py \
  --output /private/tmp/myterm-refresh-results --cycles 100
```

Choose a new output directory for each run. The runner downloads a pinned
BoringSSL archive over verified HTTPS, verifies its SHA-256, builds it in a fresh
temporary directory and compiles both native callers. `--archive <path>` accepts
an existing copy of that same archive; its hash is still verified.

Results include `refresh-results.json`, `provenance.json` and `build.log`.
Provenance records source and binary hashes, the dependency pin and compiler/build-tool versions.
Results report exact echo checks, observed shell PID continuity and fixture
timings. Disposable identity seeds stay in memory and stdin pipes.

Open [the measured refresh walkthrough](refresh.html) for the failure cases, or
[the updated account-protocol candidate](candidate.html) for the proposed design
with Gordon's agreed code format and revised refresh rule. These HTML pages
display recorded evidence and illustrative policy states; they do not run the
native protocol. Earlier probe results in the candidate are archived evidence.

## Checks

The driver keeps the original connection usable while a candidate handshake is
withheld, lost, tampered with or rejected for either peer's wrong identity pin.
It discards failed candidates and checks that the original connection still has
the same exporter observation and carries exact 256-byte/4-KiB shell echoes.

Each accelerated cycle requests KeyUpdate on both peers before delivering their
messages. Native TLS callbacks must observe new sent and received updates on
both sides. The cycle rejects a candidate with a wrong identity pin and checks
the original connection again. The driver then interleaves echoes on the old
connection with a fragmented fresh handshake. It checks the new connection before selecting it and
dropping the old contexts. Sequence-labelled echoes must return the exact ANSI
and UTF-8 output with the same server-owned shell PID throughout.

The driver also corrupts an authenticated candidate before selecting it and
checks that the original connection remains usable. An active-channel integrity
failure is a separate case: the affected TLS context must be discarded. A fresh
authenticated connection must reach the same shell. Only the detecting peer
discards the bad context automatically; the driver explicitly drops the other
peer's context. Failure of an established connection cannot be treated as a
harmless failed candidate. This distinction is motivated by
[RFC 8446, section 6](https://www.rfc-editor.org/rfc/rfc8446.html#section-6).

## Scope and remaining work

The driver selects the active channel explicitly. There is no production
attachment protocol, control lease, scheduler, automatic retry, mandatory key-use
limit or membership/revocation integration. Shell output uses synchronous
complete-line pipe echoes; this does not test a PTY, autonomous concurrent output,
queued output during handover or backlog replay. Both native callers share the
same BoringSSL implementation. Only macOS is exercised.

Any authenticated candidate can send shell input before the driver selects it.
The shell's partial-line buffer is shared across contexts. Complete-line echoes
avoid that interaction here; this does not establish selected-channel
authorization or cross-channel partial-input isolation.

The stalls and loss are injected in opaque local pipe forwarding. They do not
measure real network timeout handling. Context disposal does not implement
`close_notify`, fatal-alert forwarding or truncated-transport EOF handling.
Source comments and those limitations in the earlier probe remain applicable.

A passing accelerated run supplies regression evidence for this native probe.
It does not establish a long-term failure rate, seamless production handover,
safe production refresh intervals or security of the composed account protocol.
Production intervals remain undecided. Their selection must include the
negotiated cipher's usage limits; see
[RFC 8446, section 5.5](https://www.rfc-editor.org/rfc/rfc8446.html#section-5.5).

## Source provenance

The C TLS bridge, Ed25519 helper and initial native callers came from the
[archived trust prototype](https://github.com/GordonBeeming/myterm/tree/762a211/docs/research/trust-prototype).
The C files are unchanged. The Swift/Rust callers were extended with bounded
channel maps. The executed TLS failure cases discard only the affected candidate
context. Malformed fixture commands or allocation failure can still terminate a
native process; these local-pipe interfaces must not be exposed as network services.
These are throwaway research sources, with no production integration.
