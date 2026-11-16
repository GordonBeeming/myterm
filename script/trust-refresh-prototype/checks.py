#!/usr/bin/env python3
"""Exercise real native TLS contexts; Python selects the fixture's active channel."""
import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import statistics
import subprocess
import time


class Process:
    def __init__(self, path, server):
        self.p = subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=0)
        self.buffer = b""
        try:
            if server:
                self.send("SEED|" + secrets.token_hex(32))
            reply = self.receive().split("|")
            if len(reply) != (3 if server else 2) or reply[0] != "KEY":
                raise RuntimeError("native identity unavailable")
            self.public = reply[1]
            self.pid = int(reply[2]) if server else None
        except BaseException:
            self.close()
            raise

    def send(self, line):
        self.p.stdin.write((line + "\n").encode("ascii"))
        self.p.stdin.flush()

    def receive(self):
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(self.p.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError("native fixture response deadline exceeded")
                chunk = os.read(self.p.stdout.fileno(), 32768)
                if not chunk:
                    raise EOFError("native fixture exited")
                self.buffer += chunk
                if len(self.buffer) > 1_048_576:
                    raise RuntimeError("native response exceeds fixture bound")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode("ascii")

    def call(self, line):
        self.send(line)
        return self.receive()

    def close(self):
        try:
            if self.p.poll() is None:
                self.send("QUIT")
            self.p.wait(timeout=5)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.p.kill()
            self.p.wait(timeout=5)
        finally:
            for stream in (self.p.stdin, self.p.stdout):
                stream.close()


class Channel:
    def __init__(self, client, server, channel_id):
        self.client, self.server, self.id = client, server, channel_id
        self.open = {client: False, server: False}
        self.fingerprints = {client: "", server: ""}
        self.failures = {}
        self.queue = deque()
        self.observed_plain = bytearray()

    def frame(self, endpoint, text):
        reply = endpoint.call(text)
        if reply.startswith("FAILED|") or reply == "FAILED":
            self.open[endpoint] = False
            self.failures[endpoint] = reply
            return b"", b""
        parts = reply.split("|")
        if len(parts) != 5 or parts[0] != "FRAME":
            raise RuntimeError("unexpected native TLS frame: " + reply[:80])
        self.open[endpoint] = parts[3] == "1"
        self.fingerprints[endpoint] = parts[4]
        return bytes.fromhex(parts[1]), bytes.fromhex(parts[2])

    def start(self, wrong_server_pin=False, wrong_client_pin=False):
        client_pin = secrets.token_hex(32) if wrong_client_pin else self.client.public
        server_pin = secrets.token_hex(32) if wrong_server_pin else self.server.public
        if self.server.call(f"EXPECT|{self.id}|{client_pin}") != "READY":
            raise RuntimeError("native candidate allocation failed")
        wire, plain = self.frame(self.client, f"START|{self.id}|{server_pin}")
        if plain:
            raise RuntimeError("unexpected application plaintext during candidate setup")
        self.queue.append((self.server, wire))

    def pump_one(self, fragmented=False, tamper=False):
        target, wire = self.queue.popleft()
        if not wire:
            return
        if tamper:
            wire = wire[:-1] + bytes([wire[-1] ^ 1])
        sizes = (1, 7, 31, 127) if fragmented else (len(wire),)
        offset = index = 0
        while offset < len(wire):
            chunk = wire[offset:offset + sizes[index % len(sizes)]]
            offset += len(chunk)
            index += 1
            output, plain = self.frame(target, f"PUMP|{self.id}|{chunk.hex()}")
            self.observed_plain.extend(plain)
            if target in self.failures:
                self.queue.clear()
                return
            if output:
                self.queue.append((self.client if target is self.server else self.server, output))

    def pump(self, fragmented=False):
        steps = 0
        while self.queue:
            self.pump_one(fragmented)
            steps += 1
            if steps > 10000:
                raise RuntimeError("candidate handshake exceeded fixture pump bound")
        return all(self.open.values()) and not self.failures

    def echo(self, payload, fragmented=False):
        self.observed_plain.clear()
        wire, plain = self.frame(self.client, f"WRITE|{self.id}|{(payload + bytes([10])).hex()}")
        if plain or self.failures:
            raise RuntimeError("application write failed")
        self.queue.append((self.server, wire))
        if not self.pump(fragmented):
            raise RuntimeError("echo channel is not authenticated")
        expected = b"\x1b[32mECHO:" + str(self.server.pid).encode() + b":" + payload + b"\x1b[0m\n"
        if bytes(self.observed_plain) != expected:
            raise RuntimeError("shell PID or exact output changed")
        return wire

    def stats(self, endpoint):
        parts = endpoint.call(f"STATS|{self.id}").split("|")
        if len(parts) != 3 or parts[0] != "STATS":
            raise RuntimeError("native KeyUpdate observation unavailable")
        return tuple(int(x) for x in parts[1:])

    def drop(self):
        for endpoint in (self.client, self.server):
            if endpoint.call(f"DROP|{self.id}") != "DROPPED":
                raise RuntimeError("candidate cleanup failed")


def run(binaries, cycles):
    cases, samples, endpoints = [], [], []
    output_digest = hashlib.sha256()
    echoes = 0
    started = time.perf_counter()

    def check(value, name):
        cases.append({"name": name, "passed": bool(value)})
        if not value:
            raise RuntimeError("check failed: " + name)

    def echo(channel, label, size=256):
        nonlocal echoes
        prefix = f"{echoes:08d}:{label}:build ✓ ".encode()
        payload = (prefix + b"x" * size)[:size]
        begin = time.perf_counter_ns()
        channel.echo(payload)
        samples.append((time.perf_counter_ns() - begin) / 1e6)
        output_digest.update(payload)
        echoes += 1

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(), "status": "running", "cases": cases,
        "cycles": cycles,
        "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "limitations": [
            "Disposable multi-context Swift/Rust probe using a shared pinned BoringSSL core on macOS only.",
            "Python explicitly selects the active connection; no production handover, scheduler, control lease or attach protocol.",
            "Opaque pipe forwarding with injected stalls, loss and tampering; no real network, relay or mobile device.",
            "Shell uses pipes and synchronous complete-line echoes; no PTY, autonomous concurrent output or backlog replay.",
            "Peer membership pins are fixtures; no revocation integration or mandatory cryptographic-limit enforcement.",
            "Dropping contexts frees them locally; close_notify, fatal-alert forwarding and transport EOF remain unimplemented.",
            "Any authenticated candidate may send complete-line shell input; selected-channel authorization and cross-channel partial-line isolation are not implemented.",
            "Malformed fixture commands and allocation failure can terminate a native process; isolation claims cover only executed TLS failure cases.",
            "Only the detecting peer discards an active integrity failure automatically; the fixture explicitly drops the other peer's context.",
            "A KeyUpdate record-authentication failure aborts that connection; only failed separate candidates preserve the old channel.",
            "Short accelerated regression workload cannot establish long-term failure rates, safe production intervals or full protocol security.",
        ],
    }
    try:
        client = Process(binaries / "channel-client", False)
        endpoints.append(client)
        server = Process(binaries / "channel-server", True)
        endpoints.append(server)
        active = Channel(client, server, "initial")
        active.start()
        check(active.pump(), "initial native mutual TLS handshake")
        echo(active, "baseline")
        old_fingerprint = active.fingerprints[client]
        check(server.call(f"EXPECT|initial|{client.public}") == "REJECT|channel-limit-or-duplicate",
              "duplicate server channel ID cannot replace original context")
        check(client.call(f"START|initial|{server.public}") == "REJECT|channel-limit-or-duplicate",
              "duplicate client channel ID cannot replace original context")
        echo(active, "oldUsableAfterDuplicateIDs")

        for kind in ("badServerPin", "badClientPin", "stalled", "lost", "tampered"):
            candidate = Channel(client, server, kind)
            candidate.start(wrong_server_pin=kind == "badServerPin", wrong_client_pin=kind == "badClientPin")
            echo(active, f"oldUsableDuring{kind}")
            if kind in ("badServerPin", "badClientPin"):
                ready = candidate.pump()
                check(not ready and any("CERTIFICATE_VERIFY_FAILED" in error for error in candidate.failures.values()),
                      kind + " rejects candidate with certificate verification failure")
            elif kind == "stalled":
                check(not all(candidate.open.values()), "withheld handshake leaves candidate unready")
            elif kind == "lost":
                candidate.queue.clear()
                check(not all(candidate.open.values()), "lost handshake leaves candidate unready")
            else:
                # Deliver ClientHello, then corrupt the server's encrypted handshake flight.
                candidate.pump_one()
                candidate.pump_one(tamper=True)
                candidate.pump()
                check(client in candidate.failures and "BAD_RECORD_MAC" in candidate.failures[client],
                      "tampered encrypted handshake fails record authentication")
            echo(active, f"oldUsableAfter{kind}", 4096)
            check(active.fingerprints[client] == old_fingerprint, kind + " preserves original TLS context")
            candidate.drop()

        # Even an authenticated candidate can fail before the driver selects it.
        candidate = Channel(client, server, "postHandshakeFailure")
        candidate.start()
        check(candidate.pump(), "separate candidate authenticates without replacing original")
        candidate_wire, _ = candidate.frame(client, f"WRITE|{candidate.id}|{b'candidate'.hex()}")
        candidate.queue.append((server, candidate_wire))
        candidate.pump_one(tamper=True)
        check(server in candidate.failures and "BAD_RECORD_MAC" in candidate.failures[server],
              "authenticated candidate integrity failure discards its own context")
        echo(active, "oldUsableAfterAuthenticatedCandidateFailure", 4096)
        check(active.fingerprints[client] == old_fingerprint,
              "authenticated candidate failure preserves original TLS context")
        candidate.drop()

        seen = {old_fingerprint}
        for index in range(cycles):
            before_client, before_server = active.stats(client), active.stats(server)
            # Both peers queue an update before either peer receives the other's update.
            check(client.call(f"UPDATE|{active.id}") == "UPDATED", f"cycle {index}: queue client KeyUpdate")
            check(server.call(f"UPDATE|{active.id}") == "UPDATED", f"cycle {index}: queue server KeyUpdate")
            echo(active, f"afterSimultaneousUpdate{index}", 4096)
            after_client, after_server = active.stats(client), active.stats(server)
            check(all(a > b for a, b in zip(after_client + after_server, before_client + before_server)),
                  f"cycle {index}: native callbacks observe both sent/received updates")

            rejected = Channel(client, server, f"rejected{index}")
            rejected.start(wrong_server_pin=index % 2 == 0, wrong_client_pin=index % 2 == 1)
            ready = rejected.pump()
            check(not ready and any("CERTIFICATE_VERIFY_FAILED" in error for error in rejected.failures.values()),
                  f"cycle {index}: failed replacement rejected before switch")
            echo(active, f"oldAfterFailedReplacement{index}", 4096)
            rejected.drop()

            candidate = Channel(client, server, f"next{index}")
            candidate.start()
            echo(active, f"oldDuringReplacement{index}")
            handshake_steps = 0
            while candidate.queue:
                candidate.pump_one(fragmented=True)
                echo(active, f"oldWhileHandshakeProgresses{index}")
                handshake_steps += 1
                if handshake_steps > 10000:
                    raise RuntimeError("interleaved handshake exceeded fixture pump bound")
            check(all(candidate.open.values()) and not candidate.failures,
                  f"cycle {index}: candidate authenticated before fixture switches")
            fingerprint = candidate.fingerprints[client]
            check(bool(fingerprint) and fingerprint == candidate.fingerprints[server] and fingerprint not in seen,
                  f"cycle {index}: fresh matching exporter observation")
            seen.add(fingerprint)
            echo(candidate, f"readyBeforeSwitch{index}")
            previous, active = active, candidate
            previous.drop()
            echo(active, f"afterSwitch{index}", 4096)
            check(server.call("PID") == f"PID|{server.pid}", f"cycle {index}: same server-owned shell PID")

        # Failure of an established channel cannot be silently ignored or reused.
        invalid_payload = b"integrity-failure\n"
        wire, _ = active.frame(client, f"WRITE|{active.id}|{invalid_payload.hex()}")
        active.queue.append((server, wire))
        active.pump_one(tamper=True)
        check(server in active.failures and "BAD_RECORD_MAC" in active.failures[server],
              "tampered active record fails authentication")
        check(server.call(f"UPDATE|{active.id}") == "FAILED|no-channel",
              "failed active context is not reused as fallback")
        active.drop()
        recovered = Channel(client, server, "recovered")
        recovered.start()
        check(recovered.pump(), "fresh authenticated channel recovers after active integrity failure")
        echo(recovered, "sameShellAfterActiveFailure", 4096)
        recovered.drop()
        report["status"] = "passed"
    except Exception as error:
        report["status"] = "failed"
        report["error"] = f"{type(error).__name__}: {error}"
        raise
    finally:
        for endpoint in reversed(endpoints):
            endpoint.close()
        report.update({
            "passed": sum(case["passed"] for case in cases), "total": len(cases),
            "exact_echoes": echoes, "payload_digest_sha256": output_digest.hexdigest(),
            "elapsed_seconds": time.perf_counter() - started,
            "fixture_echo_median_ms": statistics.median(samples) if samples else None,
            "fixture_echo_max_ms": max(samples) if samples else None,
        })
        (binaries / "refresh-results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({k: v for k, v in report.items() if k not in ("cases", "limitations")}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=100)
    args = parser.parse_args()
    if not 1 <= args.cycles <= 10000:
        parser.error("cycles must be between 1 and 10000")
    run(args.binaries.resolve(), args.cycles)
