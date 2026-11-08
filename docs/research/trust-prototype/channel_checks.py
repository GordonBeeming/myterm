#!/usr/bin/env python3
"""Native TLS 1.3 and process-continuity probe through an opaque byte relay fixture."""
import argparse
from collections import deque
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import secrets
import statistics
import time

from ordering_checks import Process


class Endpoint(Process):
    def __init__(self, binaries, server):
        super().__init__([binaries / ("channel-server" if server else "channel-client")])
        self.server = server
        if server:
            self.send("SEED|" + secrets.token_hex(32))
        reply = self.receive().split("|")
        if len(reply) != (3 if server else 2) or reply[0] != "KEY":
            raise RuntimeError("native channel identity unavailable")
        self.public = reply[1]
        self.pid = int(reply[2]) if server else None
        self.open = False
        self.fingerprint = ""
        self.failed = False
        self.failure_reason = ""

    def command(self, text):
        self.send(text)
        reply = self.receive()
        if reply.startswith("FAILED"):
            self.failed = True
            self.open = False
            self.failure_reason = reply.partition("|")[2]
            return b"", b""
        p = reply.split("|")
        if len(p) != 5 or p[0] != "FRAME":
            raise RuntimeError("unexpected native TLS response")
        self.open = p[3] == "1"
        self.fingerprint = p[4]
        return bytes.fromhex(p[1]), bytes.fromhex(p[2])


class Relay:
    def __init__(self, client, server):
        self.client, self.server = client, server
        self.records = []
        self.last_server_wire = b""

    def deliver(self, target, wire, fragmented=False):
        queue = deque([(target, wire)])
        plaintext = bytearray()
        steps = 0
        while queue:
            target, data = queue.popleft()
            if not data:
                continue
            self.records.append(data)
            if target is self.client:
                self.last_server_wire = data
            sizes = (1, 7, 31, 127) if fragmented else (len(data),)
            offset, index = 0, 0
            while offset < len(data):
                size = sizes[index % len(sizes)]
                chunk = data[offset:offset+size]
                offset += len(chunk); index += 1; steps += 1
                if steps > 10000:
                    raise RuntimeError("TLS relay fixture exceeded pump bound")
                output, plain = target.command("PUMP|" + chunk.hex())
                plaintext.extend(plain)
                if target.failed:
                    return bytes(plaintext)
                if output:
                    queue.append((self.server if target is self.client else self.client, output))
        return bytes(plaintext)

    def handshake(self, wrong_client_pin=False, wrong_server_pin=False):
        self.client.failed = self.server.failed = False
        self.client.open = self.server.open = False
        self.client.fingerprint = self.server.fingerprint = ""
        self.server.send("EXPECT|" + (secrets.token_hex(32) if wrong_server_pin else self.client.public))
        if self.server.receive() != "READY":
            raise RuntimeError("native server did not initialize TLS")
        wire, plain = self.client.command("START|" + (secrets.token_hex(32) if wrong_client_pin else self.server.public))
        if plain:
            raise RuntimeError("unexpected handshake application data")
        self.deliver(self.server, wire)
        return self.client.open and self.server.open and not self.client.failed and not self.server.failed

    def echo(self, payload, fragmented=False):
        wire, plain = self.client.command("WRITE|" + (payload + b"\n").hex())
        if plain:
            raise RuntimeError("unexpected pipelined plaintext")
        result = self.deliver(self.server, wire, fragmented)
        expected = b"\x1b[32mECHO:" + str(self.server.pid).encode("ascii") + b":" + payload + b"\x1b[0m\n"
        if result != expected:
            raise RuntimeError("native shell echo differed from expected process/payload")
        return wire


def check(condition, name, cases):
    cases.append({"name": name, "passed": bool(condition)})
    if not condition:
        raise RuntimeError("channel check failed: " + name)


def stats(endpoint):
    endpoint.send("STATS")
    p = endpoint.receive().split("|")
    if len(p) != 3 or p[0] != "STATS":
        raise RuntimeError("native KeyUpdate observations unavailable")
    return int(p[1]), int(p[2])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    args = parser.parse_args()
    (args.binaries / "channel-results.json").unlink(missing_ok=True)
    client = Endpoint(args.binaries, False)
    server = Endpoint(args.binaries, True)
    cases, fresh_ms, fresh_with_echo_ms, key_update_ms, baseline_ms, rtt = [], [], [], [], [], []
    relay = Relay(client, server)
    try:
        started = time.perf_counter_ns()
        connected = relay.handshake()
        initial_ms = (time.perf_counter_ns() - started) / 1e6
        check(connected, "native Swift/Rust TLS 1.3 handshake without resumption", cases)
        check(bool(client.fingerprint) and client.fingerprint == server.fingerprint,
              "both endpoints derive the same hashed channel observation", cases)
        first_fingerprint = client.fingerprint
        marker = ("TLS_PROBE_" + secrets.token_hex(16) + " build ✓").encode("utf8")
        old_record = relay.echo(marker)
        old_server_record = relay.last_server_wire
        check(True, "encrypted channel carries UTF-8/ANSI shell output from the expected PID", cases)
        check(not any(marker in record for record in relay.records),
              "fixture byte relay does not observe the plaintext marker", cases)
        relay.echo(b"FRAGMENTED_" + secrets.token_hex(16).encode("ascii"), fragmented=True)
        check(True, "TLS records survive arbitrary fixture transport fragmentation", cases)
        for _ in range(8):
            started = time.perf_counter_ns()
            relay.echo(b"UPDATE_TIMING_PROBE")
            baseline_ms.append((time.perf_counter_ns() - started) / 1e6)
        before_client_update = stats(client)
        before_server_receive = stats(server)
        started = time.perf_counter_ns()
        client.send("UPDATE")
        check(client.receive() == "UPDATED", "client queues TLS 1.3 traffic-key update", cases)
        relay.echo(b"UPDATE_TIMING_PROBE")
        key_update_ms.append({"initiator": "client", "update_and_round_trip_ms": (time.perf_counter_ns() - started) / 1e6})
        check(stats(client)[0] > before_client_update[0] and stats(server)[1] > before_server_receive[1],
              "native message callbacks observe sent/received client KeyUpdate", cases)
        check(client.fingerprint == server.fingerprint == first_fingerprint,
              "traffic-key update preserves connection observation and process output", cases)
        before_server_update = stats(server)
        before_client_receive = stats(client)
        started = time.perf_counter_ns()
        server.send("UPDATE")
        check(server.receive() == "UPDATED", "server queues TLS 1.3 traffic-key update", cases)
        relay.echo(b"UPDATE_TIMING_PROBE")
        key_update_ms.append({"initiator": "server", "update_and_round_trip_ms": (time.perf_counter_ns() - started) / 1e6})
        check(stats(server)[0] > before_server_update[0] and stats(client)[1] > before_client_receive[1],
              "native message callbacks observe sent/received server KeyUpdate", cases)
        check(True, "server-requested key update preserves bidirectional traffic", cases)
        fingerprints = {first_fingerprint}
        for index in range(3):
            started = time.perf_counter_ns()
            check(relay.handshake(), f"fresh authenticated connection replacement {index+1}", cases)
            fresh_ms.append((time.perf_counter_ns() - started) / 1e6)
            check(client.fingerprint == server.fingerprint and client.fingerprint not in fingerprints,
                  f"connection replacement {index+1} has a fresh channel observation", cases)
            fingerprints.add(client.fingerprint)
            relay.echo(f"SAME_SHELL_AFTER_RECONNECT_{index}".encode("ascii"))
            fresh_with_echo_ms.append((time.perf_counter_ns() - started) / 1e6)
        server.send("PID")
        check(server.receive() == f"PID|{server.pid}", "server-owned shell PID survives all channel replacements", cases)
        for size in (256, 4096):
            for index in range(16):
                payload = (f"build-output-{index}:".encode("ascii") + b"x" * size)[:size]
                started = time.perf_counter_ns()
                relay.echo(payload)
                rtt.append({"payload_bytes": size, "round_trip_ms": (time.perf_counter_ns() - started) / 1e6})
        check(True, "repeatable 256-byte/4-KiB workload preserves exact output", cases)

        # Stale ciphertext must not become valid in the fresh connection.
        relay.deliver(server, old_record)
        check(server.failed and "BAD_RECORD_MAC" in server.failure_reason, "old connection ciphertext rejected after fresh handshake", cases)
        server.send("PUMP|00")
        check(server.receive() == "FAILED|no-channel", "late packet after failure does not exit the server", cases)
        server.send("UPDATE")
        check(server.receive() == "FAILED|no-channel", "late update request does not exit the server", cases)
        check(relay.handshake(), "valid channel reconnects after stale ciphertext rejection", cases)
        relay.deliver(client, old_server_record)
        check(client.failed and "BAD_RECORD_MAC" in client.failure_reason,
              "old server-to-client ciphertext rejected after fresh handshake", cases)
        check(relay.handshake(), "valid channel reconnects after reverse-direction stale record", cases)
        current = relay.echo(b"REPLAY_ON_CURRENT_CONNECTION")
        relay.deliver(server, current)
        check(server.failed and "BAD_RECORD_MAC" in server.failure_reason, "already processed record rejected within the same connection", cases)
        check(relay.handshake(), "valid channel reconnects after replay rejection", cases)
        wire, _ = client.command("WRITE|" + b"TAMPERED_MARKER\n".hex())
        changed = bytearray(wire); changed[-1] ^= 1
        relay.deliver(server, bytes(changed))
        check(server.failed and "BAD_RECORD_MAC" in server.failure_reason, "modified authenticated record rejected", cases)
        check(relay.handshake(), "channel reconnects before reverse-direction negative cases", cases)
        relay.echo(b"SERVER_RECORD_REPLAY")
        relay.deliver(client, relay.last_server_wire)
        check(client.failed and "BAD_RECORD_MAC" in client.failure_reason, "replayed server-to-client record rejected", cases)
        client.send("PUMP|00")
        check(client.receive() == "FAILED|no-channel", "late packet after failure does not exit the client", cases)
        check(relay.handshake(), "channel reconnects after reverse-direction replay", cases)
        wire, _ = client.command("WRITE|" + b"SERVER_RECORD_TAMPER\n".hex())
        response, _ = server.command("PUMP|" + wire.hex())
        changed = bytearray(response); changed[-1] ^= 1
        relay.deliver(client, bytes(changed))
        check(client.failed and "BAD_RECORD_MAC" in client.failure_reason, "modified server-to-client record rejected", cases)
        check(not relay.handshake(wrong_client_pin=True) and client.failed,
              "client rejects substituted server identity", cases)
        check(not relay.handshake(wrong_server_pin=True) and server.failed,
              "server rejects unapproved client identity", cases)
        check(relay.handshake(), "known endpoint identities reconnect after failed handshakes", cases)
        relay.echo(b"SHELL_SURVIVES_NEGATIVE_CASES")
        check(True, "same shell still produces exact output after negative cases", cases)
        report = {"generated_at": datetime.now(timezone.utc).isoformat(), "passed": sum(c["passed"] for c in cases),
                  "total": len(cases), "cases": cases,
                  "workload": {"initial_fixture_handshake_ms": initial_ms, "fresh_fixture_handshake_ms": fresh_ms,
                               "fresh_handshake_and_echo_ms": fresh_with_echo_ms,
                               "baseline_marker_round_trip_ms": baseline_ms, "traffic_key_update_timings": key_update_ms,
                               "round_trips": rtt, "median_round_trip_ms": statistics.median(r["round_trip_ms"] for r in rtt)},
                  "limitations": ["Both native callers share pinned BoringSSL; not independent TLS implementations",
                                  "Endpoint membership pins are trusted fixtures; no account/directory key bootstrap",
                                  "Opaque Python pipe relay, not deployed WebSocket/direct network transport",
                                  "Hashed TLS exporter observation is not a traffic key or proof of forward secrecy",
                                  "KeyUpdate API calls are explicit; automatic schedules and compromise recovery are not implemented/tested",
                                  "Certificate expiry/future dates and copied-certificate/wrong-private-key attacks are not negative-tested; self-signed certificate dates are not revocation authority",
                                  "Fatal-alert forwarding, close_notify and truncated-transport EOF handling are not implemented in this memory-BIO adapter",
                                  "A real server-owned /bin/sh process uses pipes, not a PTY or the production attachment/control protocol",
                                  "Timing includes fixture IPC, certificate setup and shell echo; not network latency or a production budget",
                                  "Only macOS tested; no iOS/iPadOS, Linux or Windows build evidence",
                                  "No specialist audit or complete composed-protocol security approval"]}
        (args.binaries / "channel-results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"channel_checks_passed": report["passed"], "total": report["total"]}))
    finally:
        for endpoint in (client, server):
            if endpoint.p.poll() is None:
                endpoint.send("QUIT")
                endpoint.p.wait(timeout=5)
            endpoint.close()


if __name__ == "__main__":
    main()
