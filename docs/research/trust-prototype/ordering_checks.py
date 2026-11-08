#!/usr/bin/env python3
"""Adversarial checks for the disposable single-authority native removal prototype."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import secrets
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


class Process:
    def __init__(self, argv):
        self.p = subprocess.Popen([str(x) for x in argv], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, bufsize=0)
        self.buffer = b""

    def send(self, text):
        self.p.stdin.write((text + "\n").encode("ascii"))
        self.p.stdin.flush()

    def receive(self):
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(self.p.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise RuntimeError("native process did not respond")
                chunk = os.read(self.p.stdout.fileno(), 32768)
                if not chunk:
                    raise EOFError("native process exited")
                self.buffer += chunk
                if len(self.buffer) > 32768:
                    raise RuntimeError("native response exceeded fixture limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode("ascii")

    def close(self):
        if self.p.poll() is None:
            self.p.terminate()
        try:
            self.p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.p.kill()
            self.p.wait(timeout=5)
        self.p.stdin.close()
        self.p.stdout.close()


class Client(Process):
    def __init__(self, binaries):
        super().__init__([binaries / "ordering-client"])
        reply = self.receive().split("|")
        if len(reply) != 2 or reply[0] != "KEY":
            raise RuntimeError("client did not supply its public key")
        self.public = reply[1]

    def sign(self, body):
        self.send("SIGN|" + body.encode("ascii").hex())
        reply = self.receive().split("|")
        if len(reply) != 2 or reply[0] != "SIGNATURE":
            raise RuntimeError("client did not sign request")
        return reply[1]

    def verify(self, public, body_hex, signature):
        self.send(f"VERIFY|{public}|{body_hex}|{signature}")
        return self.receive() == "VALID"


class Server(Process):
    def __init__(self, binaries, journal, seed, account, peers, crash=False):
        super().__init__([binaries / "ordering-server", journal] + (["--fixture-crash-after-commit"] if crash else []))
        # A disposable fixture seed stays in this driver and pipe memory for restart checks.
        self.send("KEY|" + seed)
        reply = self.receive().split("|")
        if len(reply) != 2 or reply[0] != "KEY":
            raise RuntimeError("server did not supply public key")
        self.public = reply[1]
        self.send("BOOT|" + account + "|" + ",".join(sorted(peers + [self.public])))
        self.ready = self.receive()

    def state(self):
        self.send("STATE")
        result = self.receive().split("|")
        if len(result) != 4 or result[0] != "STATE":
            raise RuntimeError("server state unavailable")
        return {"sequence": int(result[1]), "head": result[2], "members": result[3].split(",")}

    def remove(self, body, signature):
        self.send(f"REMOVE|{body.encode('ascii').hex()}|{signature}")
        return self.receive()


def request(account, head, issuer, target, nonce=None):
    return "|".join(["R0", account, "1", head, issuer, target, nonce or secrets.token_hex(32), "0" * 64])


def checked(condition, name, cases):
    cases.append({"name": name, "passed": bool(condition)})
    if not condition:
        raise RuntimeError("check failed: " + name)


def checkpoint_comparison(pinned, offered):
    if offered["sequence"] < pinned["sequence"]:
        return "rollback"
    if offered["sequence"] == pinned["sequence"]:
        return "same" if offered["head"] == pinned["head"] else "fork"
    return "extension-proof-required"


def compare_in_fresh_process(checkpoint_path, offered_path):
    return subprocess.check_output([sys.executable, str(Path(__file__).resolve()),
                                    "--compare-checkpoint", str(checkpoint_path), str(offered_path)],
                                   text=True, timeout=10).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path)
    parser.add_argument("--compare-checkpoint", nargs=2, type=Path)
    args = parser.parse_args()
    if args.compare_checkpoint:
        pinned, offered = (json.loads(path.read_text()) for path in args.compare_checkpoint)
        print(checkpoint_comparison(pinned, offered))
        return
    if args.binaries is None:
        parser.error("--binaries is required for native checks")
    (args.binaries / "ordering-results.json").unlink(missing_ok=True)
    cases = []
    clients = [Client(args.binaries), Client(args.binaries)]
    a, b = clients
    active = []
    try:
        with tempfile.TemporaryDirectory(prefix="ordering-fixtures-", dir=args.binaries) as scratch:
            scratch = Path(scratch)
            seed, account = secrets.token_hex(32), secrets.token_hex(32)
            peers = [a.public, b.public]
            journal = scratch / "journal"
            server = Server(args.binaries, journal, seed, account, peers)
            active.append(server)
            checked(server.ready.startswith("READY|"), "native authority starts from pinned fixture", cases)
            initial = server.state()
            baseline = journal.read_bytes()
            a_body = request(account, initial["head"], a.public, b.public)
            b_body = request(account, initial["head"], b.public, a.public)
            a_sig, b_sig = a.sign(a_body), b.sign(b_body)

            # Signature failure must leave the authoritative state untouched.
            bad_signature = ("0" if a_sig[0] != "0" else "1") + a_sig[1:]
            checked(server.remove(a_body, bad_signature) == "REJECT|signature" and server.state() == initial,
                    "forged request cannot mutate state", cases)
            other_account_body = request(secrets.token_hex(32), initial["head"], a.public, b.public)
            checked(server.remove(other_account_body, a.sign(other_account_body)) == "REJECT|request-context",
                    "cross-account request rejected", cases)
            wrong_epoch = a_body.replace("|1|", "|2|", 1)
            checked(server.remove(wrong_epoch, a.sign(wrong_epoch)) == "REJECT|request-context",
                    "request for another authority epoch rejected", cases)
            wrong_purpose = a_body[:-64] + "1" * 64
            checked(server.remove(wrong_purpose, a.sign(wrong_purpose)) == "REJECT|request-purpose",
                    "unknown signed request purpose rejected", cases)
            unknown_target = request(account, initial["head"], a.public, secrets.token_hex(32))
            checked(server.remove(unknown_target, a.sign(unknown_target)) == "REJECT|unknown-target",
                    "signed request cannot remove an unknown identity", cases)
            receipt = server.remove(a_body, a_sig)
            parts = receipt.split("|")
            checked(len(parts) == 5 and parts[0] == "COMMIT", "first signed removal commits", cases)
            authority_pin = server.public
            checked(a.verify(authority_pin, parts[1], parts[2]), "native Swift verifies receipt signature against fixture authority pin", cases)
            committed = server.state()
            checked(committed["sequence"] == 1 and b.public not in committed["members"],
                    "commit removes B from authoritative membership", cases)
            checked(server.remove(b_body, b_sig) == "REJECT|removed-issuer" and server.state() == committed,
                    "competing removal from removed key cannot commit", cases)
            late = request(account, committed["head"], b.public, a.public)
            checked(server.remove(late, b.sign(late)) == "REJECT|removed-issuer",
                    "freshly signed request from removed identity rejected", cases)
            before_retry = journal.read_bytes()
            checked(server.remove(a_body, a_sig) == receipt and journal.read_bytes() == before_retry,
                    "exact retry returns original receipt without another append", cases)
            checked(server.remove(a_body, a.sign(a_body)) == receipt and server.state() == committed,
                    "retry with randomized client signature keeps original commit", cases)
            changed = request(account, committed["head"], a.public, a.public, a_body.split("|")[6])
            checked(server.remove(changed, a.sign(changed)) == "REJECT|nonce-conflict",
                    "request ID cannot be reused for a different operation", cases)
            stale = request(account, initial["head"], a.public, a.public)
            checked(server.remove(stale, a.sign(stale)) == "REJECT|stale-checkpoint",
                    "active issuer must refresh stale checkpoint", cases)
            transfer = request(account, committed["head"], a.public, server.public)
            checked(server.remove(transfer, a.sign(transfer)) == "REJECT|authority-transfer-required",
                    "removing authority is blocked pending explicit transfer", cases)
            second = Server(args.binaries, journal, seed, account, peers)
            active.append(second)
            checked(second.ready == "FATAL|journal-already-locked", "OS lock rejects second journal writer", cases)
            second.close(); active.remove(second)
            server.close(); active.remove(server)

            restored = Server(args.binaries, journal, seed, account, peers)
            active.append(restored)
            checked(restored.state() == committed, "native restart replays signed journal", cases)
            checked(restored.remove(a_body, a_sig) == receipt, "retry after restart remains idempotent", cases)
            restored.close(); active.remove(restored)

            # Process loss after fsync but before a response must not duplicate a commit.
            crash_journal = scratch / "crash-journal"
            crash = Server(args.binaries, crash_journal, seed, account, peers, crash=True)
            active.append(crash)
            crash.send(f"REMOVE|{a_body.encode('ascii').hex()}|{a_sig}")
            checked(crash.p.wait(timeout=10) == 42, "fixture exits after journal sync before acknowledgement", cases)
            crash.close(); active.remove(crash)
            recovered = Server(args.binaries, crash_journal, seed, account, peers)
            active.append(recovered)
            checked(recovered.state() == committed and recovered.remove(a_body, a_sig) == receipt,
                    "lost acknowledgement recovers the original commit", cases)
            recovered.close(); active.remove(recovered)

            # The other arrival order must also commit only its first authorized operation.
            reverse = Server(args.binaries, scratch / "reverse-journal", seed, account, peers)
            active.append(reverse)
            reverse_receipt = reverse.remove(b_body, b_sig)
            checked(reverse_receipt.startswith("COMMIT|") and reverse.remove(a_body, a_sig) == "REJECT|removed-issuer",
                    "opposite arrival order commits only B's removal of A", cases)
            reverse.close(); active.remove(reverse)

            corrupt = scratch / "corrupt-journal"
            corrupt.write_bytes(journal.read_bytes().replace(parts[2].encode("ascii"), bad_signature.encode("ascii"), 1))
            rejected = Server(args.binaries, corrupt, seed, account, peers)
            active.append(rejected)
            checked(rejected.ready == "FATAL|signature", "tampered committed receipt signature prevents startup", cases)
            rejected.close(); active.remove(rejected)
            invalid_record = scratch / "invalid-record-journal"
            invalid_record.write_bytes(baseline + b"NOT-A-COMMIT\n")
            rejected = Server(args.binaries, invalid_record, seed, account, peers)
            active.append(rejected)
            checked(rejected.ready == "FATAL|journal-record", "invalid complete journal record prevents startup", cases)
            rejected.close(); active.remove(rejected)
            truncated = scratch / "truncated-journal"
            truncated.write_bytes(journal.read_bytes()[:-1])
            rejected = Server(args.binaries, truncated, seed, account, peers)
            active.append(rejected)
            checked(rejected.ready == "FATAL|journal-truncated", "incomplete journal fails closed", cases)
            rejected.close(); active.remove(rejected)

            # The Rust journal alone does not fence a restored old copy. A client with a
            # pinned checkpoint must reject the conflicting extension, not overwrite it.
            fork_journal = scratch / "rolled-back-journal"
            fork_journal.write_bytes(baseline)
            fork = Server(args.binaries, fork_journal, seed, account, peers)
            active.append(fork)
            checkpoint_path = scratch / "client-checkpoint.json"
            checkpoint_path.write_text(json.dumps({"sequence": 1, "head": committed["head"]}))
            offered_path = scratch / "offered-state.json"
            offered_path.write_text(json.dumps(fork.state()))
            checked(compare_in_fresh_process(checkpoint_path, offered_path) == "rollback",
                    "fresh reference verifier rejects actual older offered STATE using saved checkpoint", cases)
            fork_receipt = fork.remove(b_body, b_sig)
            fp = fork_receipt.split("|")
            fork_head = hashlib.sha256((fp[1] + "|" + fp[2]).encode("ascii")).hexdigest()
            checked(a.verify(authority_pin, fp[1], fp[2]) and fork_head != committed["head"],
                    "negative control: restored authority can sign a valid fork", cases)
            offered_path.write_text(json.dumps(fork.state()))
            checked(compare_in_fresh_process(checkpoint_path, offered_path) == "fork",
                    "fresh reference verifier detects actual equal-sequence fork using saved checkpoint", cases)
            fork.close(); active.remove(fork)
            report = {"generated_at": datetime.now(timezone.utc).isoformat(),
                      "prototype": "single trusted Rust removal authority with native Swift signed requests/receipt signature verification",
                      "passed": sum(c["passed"] for c in cases), "total": len(cases), "cases": cases,
                      "limitations": ["Fixture account bootstrap and coordinator key pinning, not real enrollment",
                                      "Coordinator seed retained in driver memory for restart; no product key storage",
                                      "Single honest authority; no consensus, authority transfer or automatic failover",
                                      "No protection against authority key compromise, old snapshot signing or key cloning; fork negative control demonstrates this",
                                      "Checkpoint rejection conditions are exercised by the Python harness, not implemented in the Swift product client",
                                      "Outage leaves no authority process to commit a request; no live terminal transport is exercised",
                                      "Only native macOS tested; OS journal lock is Unix-only in this probe",
                                      "Process-exit recovery is not evidence for physical power-loss/filesystem guarantees",
                                      "No offline deployment enrollment or directory-key rotation implemented"]}
            (args.binaries / "ordering-results.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps({"ordering_checks_passed": report["passed"], "total": report["total"]}))
    finally:
        for process in active + clients:
            process.close()


if __name__ == "__main__":
    main()
