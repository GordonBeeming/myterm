#!/usr/bin/env python3
"""CryptoKit-to-BoringSSL authenticated HPKE and encrypted directory snapshot probe."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import secrets
from ordering_checks import Process


class Sender(Process):
    def __init__(self, binaries):
        super().__init__([binaries / "directory-sender"])
        first = self.receive().split("|")
        if len(first) != 2 or first[0] != "SENDER":
            raise RuntimeError("native sender identity unavailable")
        self.public = first[1]

    def epoch(self, number, account, checkpoint, plaintext):
        self.send(f"EPOCH|{number}|{account}|{checkpoint}|{plaintext.hex()}")
        p = self.receive().split("|")
        if len(p) != 4 or p[0] != "EPOCH":
            raise RuntimeError("native directory epoch unavailable")
        return {"context": p[1], "snapshot": p[2], "key_digest": p[3]}

    def envelope(self, recipient):
        self.send("ENVELOPE|" + recipient.public)
        p = self.receive().split("|")
        if len(p) != 3 or p[0] != "ENVELOPE":
            raise RuntimeError("native key envelope unavailable")
        return {"enc": p[1], "wrapped": p[2]}


class Recipient(Process):
    def __init__(self, binaries):
        super().__init__([binaries / "directory-recipient"])
        p = self.receive().split("|")
        if len(p) != 2 or p[0] != "RECIPIENT":
            raise RuntimeError("native recipient identity unavailable")
        self.public = p[1]

    def pin(self, account, epoch, checkpoint, sender):
        self.send(f"PIN|{account}|{epoch}|{checkpoint}|{sender}")
        return self.receive()

    def advance(self, epoch, checkpoint):
        self.send(f"ADVANCE|{epoch}|{checkpoint}")
        return self.receive()

    def open(self, package, envelope):
        self.send(f"OPEN|{package['context']}|{envelope['enc']}|{envelope['wrapped']}|{package['snapshot']}")
        return self.receive()

    def delegate(self, recipient):
        self.send('DELEGATE|' + recipient.public)
        p = self.receive().split('|')
        if len(p) != 3 or p[0] != 'ENVELOPE':
            raise RuntimeError('native delegated key envelope unavailable')
        return {'enc': p[1], 'wrapped': p[2]}


def changed(hex_value):
    data = bytearray.fromhex(hex_value)
    data[-1] ^= 1
    return data.hex()


def check(value, name, cases):
    cases.append({"name": name, "passed": bool(value)})
    if not value:
        raise RuntimeError("directory check failed: " + name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    args = parser.parse_args()
    (args.binaries / "directory-results.json").unlink(missing_ok=True)
    processes = []
    cases = []
    try:
        sender = Sender(args.binaries); processes.append(sender)
        unauthorized = Sender(args.binaries); processes.append(unauthorized)
        b = Recipient(args.binaries); processes.append(b)
        c = Recipient(args.binaries); processes.append(c)
        account, checkpoint = secrets.token_hex(32), secrets.token_hex(32)
        plain = 'fixture-directory: native-server@example.invalid; label=开发 ✓'.encode('utf8')
        package = sender.epoch(1, account, checkpoint, plain)
        envelope_b, envelope_c = sender.envelope(b), sender.envelope(c)
        check(b.public != c.public, "native recipients generate distinct private/public key pairs", cases)
        check(b.pin(account, 1, checkpoint, sender.public) == c.pin(account, 1, checkpoint, sender.public) == "PINNED",
              "native recipients pin account/sender/epoch/checkpoint fixture", cases)
        expected = "OPENED|" + plain.hex() + "|" + package['key_digest']
        check(b.open(package, envelope_b) == expected, "Rust/BoringSSL opens CryptoKit authenticated HPKE and AES-GCM snapshot", cases)
        check(c.open(package, envelope_c) == expected, "same directory key delivered independently to second recipient", cases)
        check(envelope_b != envelope_c, "per-recipient envelopes differ", cases)
        check(b.open(package, envelope_c) == "REJECT|authentication", "recipient cannot open another endpoint's envelope", cases)
        bad_envelope = {**envelope_b, "wrapped": changed(envelope_b['wrapped'])}
        check(b.open(package, bad_envelope) == "REJECT|authentication", "modified wrapped directory key rejected", cases)
        bad_enc = {**envelope_b, "enc": changed(envelope_b['enc'])}
        check(b.open(package, bad_enc) == "REJECT|authentication", "modified encapsulated key rejected", cases)
        bad_snapshot = {**package, "snapshot": changed(package['snapshot'])}
        check(b.open(bad_snapshot, envelope_b) == "REJECT|authentication", "modified encrypted snapshot rejected", cases)
        fields = bytes.fromhex(package['context']).decode('ascii').split('|')
        fields[1] = secrets.token_hex(32)
        check(b.open({**package, "context": '|'.join(fields).encode().hex()}, envelope_b) == "REJECT|context",
              "cross-account snapshot context rejected", cases)
        fields[1] = account; fields[3] = secrets.token_hex(32)
        check(b.open({**package, "context": '|'.join(fields).encode().hex()}, envelope_b) == "REJECT|context",
              "snapshot for another membership checkpoint rejected", cases)
        forged = unauthorized.epoch(1, account, checkpoint, plain)
        check(b.open(forged, unauthorized.envelope(b)) == "REJECT|authentication",
              "unapproved sender cannot authenticate a directory key envelope", cases)
        # Rotation belongs to the trusted fixture. No new envelope is issued for removed B.
        next_checkpoint = secrets.token_hex(32)
        rotated = sender.epoch(2, account, next_checkpoint, plain + b'; rotation=2')
        next_c = sender.envelope(c)
        check(rotated['key_digest'] != package['key_digest'], "rotation uses a fresh directory key", cases)
        check(c.advance(2, next_checkpoint) == "ADVANCED", "remaining recipient advances its pinned epoch/checkpoint", cases)
        next_expected = "OPENED|" + (plain + b'; rotation=2').hex() + "|" + rotated['key_digest']
        check(c.open(rotated, next_c) == next_expected, "remaining recipient opens rotated directory", cases)
        check(c.open(package, envelope_c) == "REJECT|context", "older directory envelope rejected after epoch advance", cases)
        check(c.advance(1, checkpoint) == "REJECT|epoch", "recipient cannot roll back pinned epoch", cases)
        check(b.open(package, envelope_b) == expected, "removed holder can still decrypt retained old ciphertext", cases)
        check(b.advance(2, next_checkpoint) == "ADVANCED", "negative control gives removed holder the new public context", cases)
        check(b.open(rotated, next_c) == "REJECT|authentication", "removed recipient cannot use remaining recipient's new envelope", cases)
        mismatched = {**rotated, "snapshot": package['snapshot']}
        check(c.open(mismatched, next_c) == "REJECT|authentication", "old snapshot cannot be paired with new epoch/key envelope", cases)
        check(c.pin(account, 1, checkpoint, unauthorized.public) == "REJECT|already-pinned",
              "existing account/sender pin cannot be silently replaced", cases)
        b.send('DELEGATE|' + c.public)
        check(b.receive() == 'REJECT|no-bootstrap-key',
              'holder cannot relabel an old cached directory key with a newer context', cases)
        holder = Recipient(args.binaries); processes.append(holder)
        new_server = Recipient(args.binaries); processes.append(new_server)
        check(holder.pin(account, 2, next_checkpoint, sender.public) == 'PINNED'
              and holder.open(rotated, sender.envelope(holder)) == next_expected,
              'deployment capability holder receives a prepared directory key envelope', cases)
        sender.send('QUIT'); sender.p.wait(timeout=5)
        check(new_server.pin(account, 2, next_checkpoint, holder.public) == 'PINNED',
              'new server pins authorized deployment-holder key from credential fixture', cases)
        delegated = holder.delegate(new_server)
        check(new_server.open(rotated, delegated) == next_expected,
              'offline holder rewraps directory key to new independent server after original sender exits', cases)
        report = {"generated_at": datetime.now(timezone.utc).isoformat(),
                  "prototype": "native CryptoKit authenticated HPKE/AES-GCM sender to native Rust/BoringSSL recipients",
                  "passed": sum(c['passed'] for c in cases), "total": len(cases), "cases": cases,
                  "limitations": ["Independent CryptoKit/BoringSSL interop on macOS only; no other OS/device validation",
                                  "Membership, sender key-purpose binding, removal and epoch/checkpoint advancement are trusted fixtures, not integrated signed-account state",
                                  "The sender omits a removed recipient's new envelope; this does not prevent a still-authorized compromised sender from leaking keys",
                                  "HPKE recipient keys are long-lived for this process; retained ciphertext lacks forward secrecy against later recipient-key compromise",
                                  "Old copied keys/ciphertext remain readable; revocation does not erase past access",
                                  "No public directory-key plaintext is emitted; only fingerprints, encrypted snapshots and recipient-local fixture plaintext",
                                  "No durable keystore, client checkpoint persistence, full directory version/merge protocol or automatic rotation scheduling",
                                  "Offline capability-key import, signed delegation validation and production enrollment transport are not exercised by these cryptographic checks",
                                  "No specialist audit or secure full-protocol approval"]}
        (args.binaries / 'directory-results.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({"directory_checks_passed": report['passed'], "total": report['total']}))
    finally:
        for p in processes:
            if p.p.poll() is None:
                p.send('QUIT'); p.p.wait(timeout=5)
            p.close()


if __name__ == '__main__':
    main()
