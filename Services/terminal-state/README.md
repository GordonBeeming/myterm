# Local terminal checkpoints

A checkpoint-enabled local Rust session owns a real WezTerm emulator alongside its PTY. The daemon feeds it while attached and detached. A fresh native view imports both buffers, retained history and supported emulator state, then consumes ordered output and resize events. The snapshot carries unfinished parser input needed to complete the next token.

The Rust checkpoint path is opt-in. The ordinary terminal still uses the native SwiftTerm path while this engine and import bridge are being validated.

## Build and test

On macOS with Xcode, Python 3.12+ and the Rust 1.99.1 toolchain:

```sh
bash Services/terminal-state/check.sh
```

The command prepares and verifies the pinned source archives, runs the Rust engine and local daemon tests, then passes the PTY test's snapshot and live bytes into an unwindowed native SwiftTerm view. It checks the default 5,000 history lines at 160 columns, a larger history cut, and a Kitty image over 256 KiB. The PTY fixtures supply a test authenticator to the production socket code. Production peer-signing checks still run in the packaged daemon.

## Dependencies and upkeep

WezTerm is pinned to `458a100c1bf4134d36cb5c42dd90e4c8266d9e1a`. Its finl_unicode dependency is pinned to `a1892f26245529f2ef3877a9ebd610c96cec07a6`. The preparation script checks the SHA-256 of both archives and applies the checked-in patch with zero fuzz. Cargo resolves registry dependencies from the lockfiles.

The patch incorporates the retained parser, resize and image compatibility corrections, and adds compact row encoding and a synchronous bounded reply writer. The terminal-state crate depends on the patched source because checkpoint export needs emulator state that upstream WezTerm keeps private. Upgrade the pin and patch together and rerun native fixtures with each change. [Retained feasibility and acceptance links](https://github.com/GordonBeeming/myterm/issues/150).

The source notices for WezTerm's MIT license and finl_unicode's MIT, Apache 2.0 and Unicode terms are included under [dependencies/licenses](dependencies/licenses). A distribution containing the daemon needs its third-party notices and a review of the resolved transitive licenses for each target.

## Local attachment protocol

Frame headers carry a one-byte tag and a four-byte big-endian payload length. The maximum payload is 65,536 bytes. Existing start and attachment tags retain their wire format.

| Tag | Direction | Contents |
| --- | --- | --- |
| 11 | Client | Launch with two UUIDs and launch JSON. In addition to grid columns and rows, supply measured physical-pixel `cellWidth` and `cellHeight`. Optional `scrollback` defaults to 5,000 and accepts up to 100,000. |
| 12 | Client | Attach with the session and client UUIDs. |
| 13 | Client | Acknowledge the imported checkpoint with its eight-byte sequence. |
| 14 | Client | Stop from a separate socket with the session, client and expected owner UUIDs, followed by the eight-byte revision. |
| 15 | Client | Read the control state with the session and client UUIDs, then close. |
| 0x81 | Server | Ready with server PID, shell PID and a ninth byte set to 1 for a checkpoint attachment. |
| 0x84 | Server | Current controller, revision and connection state. |
| 0x86 | Server | Begins the checkpoint with its eight-byte sequence and four-byte total byte length. |
| 0x87 | Server | Checkpoint bytes, in order. |
| 0x82 | Server | Live terminal output after the checkpoint cut. |
| 0x88 | Server | Applied geometry. Checkpoint connections use four big-endian UInt16 values for columns, rows, cell width and cell height. Send resize tag 4 with the same payload. |

The daemon takes the snapshot on its PTY event loop before publishing later stream events. A client verifies the sequence from the begin frame during import and sends tag 13 before sending input, resizing or requesting control. Only the daemon sends terminal-generated replies to the PTY. The native view uses `sendsTerminalResponses = false` on this connection.

Encoded snapshots are capped at 32 MiB. The exporter keeps both viewports and uses the remaining native checkpoint budget for the newest history. The snapshot records how many older rows it omitted. The daemon caps in-flight snapshot bytes at 64 MiB, with one bounded live queue per connection. A slow connection may disconnect and request a new cut. If visible state or image data still exceeds the checkpoint bounds, attachment returns an error. The daemon keeps the live shell and configured history. Session state is in memory in the owning daemon.

## Design considerations

- Existing callers use distinct launch and attach tags. Checkpoint clients require version 3 in the snapshot and acknowledge the matching sequence.
- Local socket peer authentication precedes access. Control is fenced by the current owner and revision. A retry replaces only the same client's connection, and the session UUID prevents a duplicate shell.
- Errors for oversized or unrepresented state end the attach attempt. The daemon logs execution failures without recording terminal contents or transferred snapshots.
- The PTY event loop owns state and replies. Clients rebuild from the next checkpoint after a stream gap. A restart of the daemon ends its owned sessions, so the native process-recovery workflows still apply.
- Each running session retains its configured history, with separate bounds on transfer bytes, encoded cells, glyphs, images, parser continuations and outstanding delivery. The daemon serializes export with PTY events to give the kept history and live stream one cut.
- Preparation downloads public archives at build time over verified HTTPS. Each download has a timeout and is checked against a fixed digest before replacing cached sources. Runtime checkpoint traffic stays on the authenticated local socket.

## Open acceptance

The exporter rejects active palette overrides, open or parameterized hyperlinks, non-ASCII charsets, some extended terminal modes, unsupported line and underline attributes, unknown partial DCS tokens and states that exceed decoder bounds. Unsupported-state detection remains incomplete for terminal extensions in the emulator's no-op paths, including synchronized output. Existing image requests need validation across live font and backing-scale changes, with animation, automatic identity, eviction and broad native graphics coverage still open. Text-only snapshots can restore with fractional native cell sizes. Snapshots with graphics or an unfinished graphics token require exact physical cell dimensions. A nine-pixel graphics snapshot therefore rejects an 8.5-point cell at 1×. It cannot establish that already prepared image stripes converge after moving a real window.

Production acceptance also needs repeated release-build workloads, real signed Mac reattachment, mobile and multi-Mac runs. [Validate production terminal checkpoints and native SwiftTerm reconnect](https://github.com/GordonBeeming/myterm/issues/189).
