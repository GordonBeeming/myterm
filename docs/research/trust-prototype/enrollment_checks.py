#!/usr/bin/env python3
"""Signed account/enrollment reference model. CryptoKit signs; policy runs in Python, not product Rust."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import sqlite3
import tempfile
import threading

from ordering_checks import Client
from directory_checks import Recipient, check

CRYPTO_LOCK = threading.Lock()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def digest(value):
    return hashlib.sha256(canonical(value).encode("ascii")).hexdigest()


ADMISSION_FIELDS = {'domain', 'account', 'issuer', 'subject', 'nonce'}
ENROLLMENT_FIELDS = {'domain', 'account', 'credential', 'subject', 'nonce', 'claimed_issued_at'}


def encoded_key(value, size):
    return isinstance(value, str) and len(value) == size and all(c in '0123456789abcdef' for c in value)


def typed_body(signed, domain, allowed_fields):
    if not isinstance(signed, dict) or set(signed) != {'body', 'signature'}:
        raise Rejected('schema')
    body = signed['body']
    if not isinstance(body, dict) or body.get('domain') != domain:
        raise Rejected('domain')
    if set(body) not in allowed_fields:
        raise Rejected('schema')
    if not encoded_key(signed['signature'], 128) or not encoded_key(body.get('account'), 64):
        raise Rejected('schema')
    if 'issuer' in body and not encoded_key(body['issuer'], 64):
        raise Rejected('schema')
    for field in ('nonce', 'credential'):
        if field in body and not encoded_key(body[field], 32):
            raise Rejected('schema')
    return body


def endpoint_manifest(manifest):
    fields = {'identity', 'tls_authentication', 'directory_recipient', 'directory_suite', 'directory_key_purposes', 'role'}
    if not isinstance(manifest, dict) or set(manifest) != fields:
        raise Rejected('schema')
    if manifest['role'] not in ('client', 'server'):
        raise Rejected('endpoint-role')
    if not encoded_key(manifest['identity'], 64) or manifest['tls_authentication'] != manifest['identity']:
        raise Rejected('subject-binding')
    if not encoded_key(manifest['directory_recipient'], 130) or not manifest['directory_recipient'].startswith('04'):
        raise Rejected('subject-binding')
    if manifest['directory_suite'] != 'HPKE-P256-SHA256-AES256GCM' or manifest['directory_key_purposes'] != ['recipient', 'authenticated-sender']:
        raise Rejected('subject-binding')


class Rejected(Exception):
    pass


@contextmanager
def database(path):
    db = sqlite3.connect(path, timeout=10)
    try:
        with db:
            yield db
    finally:
        db.close()


class Identity:
    def __init__(self, binaries, role):
        self.signer = Client(binaries)
        self.recipient = Recipient(binaries)
        self.role = role
        self.public = self.signer.public

    def manifest(self):
        return {"identity": self.public, "directory_recipient": self.recipient.public,
                "tls_authentication": self.public, 'directory_key_purposes': ['recipient', 'authenticated-sender'],
                "directory_suite": "HPKE-P256-SHA256-AES256GCM", "role": self.role}

    def sign(self, body):
        with CRYPTO_LOCK:
            return {"body": body, "signature": self.signer.sign(canonical(body))}

    def verifies(self, public, signed):
        with CRYPTO_LOCK:
            return self.signer.verify(public, canonical(signed["body"]).encode("ascii").hex(), signed["signature"])

    def close(self):
        for p in (self.signer, self.recipient):
            if p.p.poll() is None:
                p.send("QUIT"); p.p.wait(timeout=5)
            p.close()


class Account:
    def __init__(self, first, authority, pinned_anchor=None, received_genesis=None):
        if first.role != 'client' or authority.role != 'server':
            raise Rejected('genesis-role')
        self.authority = authority
        self.crypto = authority
        self.genesis = received_genesis if received_genesis is not None else first.sign(
            {"domain": "myterm-account-genesis-reference-v0", "first": first.manifest(), "ordering_server": authority.manifest()})
        if not isinstance(self.genesis, dict) or set(self.genesis) != {'body', 'signature'}:
            raise Rejected('schema')
        if not encoded_key(self.genesis['signature'], 128):
            raise Rejected('schema')
        genesis_body = self.genesis['body']
        if not isinstance(genesis_body, dict) or set(genesis_body) != {'domain', 'first', 'ordering_server'} or genesis_body['domain'] != 'myterm-account-genesis-reference-v0':
            raise Rejected('domain')
        endpoint_manifest(genesis_body['first']); endpoint_manifest(genesis_body['ordering_server'])
        if genesis_body['first'] != first.manifest() or genesis_body['ordering_server'] != authority.manifest():
            raise Rejected('subject-binding')
        if received_genesis is not None and pinned_anchor is None:
            raise Rejected('account-anchor-required')
        self.anchor = digest(self.genesis["body"])
        if pinned_anchor is not None and pinned_anchor != self.anchor:
            raise Rejected("account-anchor")
        if not authority.verifies(first.public, self.genesis):
            raise Rejected("genesis-signature")
        self.members = {first.public: first.manifest(), authority.public: authority.manifest()}
        self.removed = set()
        self.credentials = {}
        self.events = []
        self.head = digest({"anchor": self.anchor, "genesis_body": self.genesis['body']})
        self.lock = threading.RLock()

    def current(self, public):
        if public not in self.members or public in self.removed:
            raise Rejected("removed-or-unknown-issuer")

    def verify(self, public, signed):
        if not self.crypto.verifies(public, signed):
            raise Rejected("signature")

    def commit(self, payload):
        # Native Rust journal durability is checked separately. This is an in-memory policy ledger.
        record = self.authority.sign({"domain": "myterm-account-commit-reference-v0", "account": self.anchor,
                                      "sequence": len(self.events)+1, "previous": self.head, "event": payload})
        self.events.append(record); self.head = digest(record)
        return record

    def remove(self, actor, target):
        with self.lock:
            self.current(actor.public)
            if target == self.authority.public:
                raise Rejected("authority-transfer-required")
            self.current(target)
            request = actor.sign({"domain": "myterm-remove-reference-v0", "account": self.anchor, "target": target})
            self.verify(actor.public, request)
            self.commit(request)
            self.members.pop(target); self.removed.add(target)

    def approve(self, actor, subject, credential=None):
        with self.lock:
            self.current(actor.public)
            endpoint_manifest(subject.manifest())
            body = {"domain": "myterm-admission-reference-v0", "account": self.anchor,
                    "issuer": actor.public, "subject": subject.manifest(), "nonce": secrets.token_hex(16)}
            if credential is not None:
                if credential not in self.credentials:
                    raise Rejected('unknown-credential')
                body['credential'] = credential
            proof = subject.sign(body)
            return {"approval": actor.sign(body), "subject_proof": proof}

    def accept_approval(self, proof):
        with self.lock:
            if not isinstance(proof, dict) or set(proof) != {'approval', 'subject_proof'}:
                raise Rejected('schema')
            fields = [ADMISSION_FIELDS, ADMISSION_FIELDS | {'credential'}]
            body = typed_body(proof['approval'], 'myterm-admission-reference-v0', fields)
            typed_body(proof['subject_proof'], 'myterm-admission-reference-v0', fields)
            endpoint_manifest(body['subject'])
            if 'credential' in body and body['credential'] not in self.credentials:
                raise Rejected('unknown-credential')
            if body["account"] != self.anchor:
                raise Rejected("account-anchor")
            self.current(body["issuer"])
            if body != proof["subject_proof"]["body"]:
                raise Rejected("subject-binding")
            self.verify(body["issuer"], proof["approval"])
            self.verify(body["subject"]["identity"], proof["subject_proof"])
            subject = body["subject"]["identity"]
            if subject in self.removed:
                raise Rejected("explicit-reapproval-required")
            if subject in self.members:
                if self.members[subject] != body['subject']:
                    raise Rejected('subject-binding')
                return
            self.commit(proof); self.members[subject] = body["subject"]

    def credential(self, creator, role_key, expires, now, mode):
        with self.lock:
            self.current(creator.public)
            if type(expires) is not int or not 0 < expires < 2**63 or type(now) is not int or expires <= now or mode not in ("single-use", "reusable"):
                raise Rejected("credential-policy")
            if mode == 'reusable' and (role_key.role != 'credential' or role_key.public in self.members):
                raise Rejected('credential-key-purpose')
            if mode == 'single-use':
                self.current(role_key.public)
            body = {"domain": "myterm-deployment-delegation-reference-v0", "account": self.anchor,
                    "id": secrets.token_hex(16), "issuer": creator.public, "public": role_key.public,
                    "directory_recipient": role_key.recipient.public,
                    "scope": "enroll-server", "mode": mode, "expires": expires}
            certificate = creator.sign(body); self.verify(creator.public, certificate)
            self.commit(certificate)
            self.credentials[body["id"]] = {"certificate": certificate, "revoked": False}
            return body["id"]

    def revoke_credential(self, actor, credential_id):
        with self.lock:
            self.current(actor.public)
            if credential_id not in self.credentials:
                raise Rejected('unknown-credential')
            self.commit(actor.sign({"domain": "myterm-credential-revocation-reference-v0", "account": self.anchor,
                                    "credential": credential_id}))
            self.credentials[credential_id]["revoked"] = True

    def credential_current(self, credential_id, now, mode):
        record = self.credentials.get(credential_id)
        if record is None:
            raise Rejected('unknown-credential')
        body = record["certificate"]["body"]
        if record["revoked"] or now >= body["expires"]:
            raise Rejected("fresh-approval-required")
        if body["mode"] != mode:
            raise Rejected("credential-mode")
        return body

    def directory_recipients(self, now):
        if type(now) is not int or not 0 <= now < 2**63:
            raise Rejected('clock')
        recipients = {m['directory_recipient'] for key, m in self.members.items() if key not in self.removed}
        recipients.update(record['certificate']['body']['directory_recipient']
                          for record in self.credentials.values()
                          if record['certificate']['body']['mode'] == 'reusable'
                          and not record['revoked'] and now < record['certificate']['body']['expires'])
        return recipients

    def enrollment(self, credential_id, role_key, subject, claimed_time):
        # This operation can run with every pre-existing endpoint offline. Time is a claim only.
        body = {"domain": "myterm-deployment-enrollment-reference-v0", "account": self.anchor,
                "credential": credential_id, "subject": subject.manifest(),
                "nonce": secrets.token_hex(16), "claimed_issued_at": claimed_time}
        return {"delegation": role_key.sign(body), "subject_proof": subject.sign(body)}

    def validate_enrollment(self, proof, now, mode):
        if mode != 'reusable':
            raise Rejected('credential-mode')
        if not isinstance(proof, dict) or set(proof) != {'delegation', 'subject_proof'}:
            raise Rejected('schema')
        body = typed_body(proof['delegation'], 'myterm-deployment-enrollment-reference-v0', [ENROLLMENT_FIELDS])
        typed_body(proof['subject_proof'], 'myterm-deployment-enrollment-reference-v0', [ENROLLMENT_FIELDS])
        endpoint_manifest(body['subject'])
        if type(body['claimed_issued_at']) is not int or not 0 <= body['claimed_issued_at'] < 2**63:
            raise Rejected('schema')
        if body["account"] != self.anchor:
            raise Rejected("account-anchor")
        if body != proof["subject_proof"]["body"]:
            raise Rejected("subject-binding")
        subject = body["subject"]
        if subject["role"] != "server":
            raise Rejected("server-only")
        if any(record['certificate']['body']['mode'] == 'reusable' and
               (record['certificate']['body']['public'] == subject['identity'] or
                record['certificate']['body']['directory_recipient'] == subject['directory_recipient'])
               for record in self.credentials.values()):
            raise Rejected('credential-key-is-not-endpoint')
        # A recognized server authenticates with its own identity; it does not inherit credential expiry.
        self.verify(subject["identity"], proof["subject_proof"])
        if subject["identity"] in self.members:
            if self.members[subject["identity"]] != subject:
                raise Rejected("subject-binding")
            return subject, True
        if subject["identity"] in self.removed:
            raise Rejected("explicit-reapproval-required")
        credential = self.credential_current(body["credential"], now, mode)
        self.verify(credential["public"], proof["delegation"])
        return subject, False

    def accept_enrollment(self, proof, now, mode="reusable"):
        with self.lock:
            subject, known = self.validate_enrollment(proof, now, mode)
            if not known:
                self.commit(proof); self.members[subject["identity"]] = subject
            return subject["identity"]


class CachedTrust:
    """Already-verified public state carried by an endpoint; no authority RPC/signing handle."""
    current = Account.current
    verify = Account.verify
    credential_current = Account.credential_current
    validate_enrollment = Account.validate_enrollment
    approve = Account.approve
    accept_approval = Account.accept_approval
    directory_recipients = Account.directory_recipients

    def __init__(self, account, local_endpoint):
        self.anchor, self.head = account.anchor, account.head
        self.members = json.loads(canonical(account.members))
        self.credentials = json.loads(canonical(account.credentials))
        self.removed = set(account.removed)
        self.crypto = local_endpoint
        self.lock = threading.RLock()
        self.local_acceptance = []
        self.issued_admissions = {}

    def commit(self, payload):
        # This is a local witness, not an authoritative sequence or replacement checkpoint.
        witness = self.crypto.sign({'domain': 'myterm-local-acceptance-reference-v0',
                                    'account': self.anchor, 'issuer': self.crypto.public,
                                    'checkpoint': self.head, 'evidence': payload})
        self.local_acceptance.append(witness)
        return witness

    def recognize(self, proof, now):
        with self.lock:
            subject, known = self.validate_enrollment(proof, now, 'reusable')
            if not known:
                self.commit(proof)
                self.members[subject['identity']] = subject
            return subject['identity']

    def certify_enrollment(self, proof, subject, now):
        with self.lock:
            self.current(self.crypto.public)
            if subject.public in self.removed:
                raise Rejected('explicit-reapproval-required')
            if subject.manifest() != proof['delegation']['body']['subject']:
                raise Rejected('subject-binding')
            previous = self.issued_admissions.get(subject.public)
            if previous is not None:
                if previous['approval']['body']['subject'] != subject.manifest():
                    raise Rejected('subject-binding')
                return previous
            credential = proof['delegation']['body']['credential']
            self.credential_current(credential, now, 'reusable')
            self.recognize(proof, now)
            admission = self.approve(self.crypto, subject, credential=credential)
            self.issued_admissions[subject.public] = admission
            return admission


class SingleUseIssuer:
    def __init__(self, account, role_key, path):
        self.account, self.role_key, self.path = account, role_key, path
        with database(path) as db:
            db.execute("CREATE TABLE invitations (id TEXT PRIMARY KEY, token_hash TEXT NOT NULL, receipt TEXT)")

    def issue(self, creator, now, expires):
        credential = self.account.credential(creator, self.role_key, expires, now, "single-use")
        token = secrets.token_bytes(32)
        with database(self.path) as db:
            db.execute("INSERT INTO invitations VALUES (?, ?, NULL)", (credential, hashlib.sha256(token).hexdigest()))
        return credential, token

    def request(self, credential, subject):
        body = {"domain": "myterm-admission-reference-v0", "account": self.account.anchor,
                "issuer": self.role_key.public, "credential": credential,
                "subject": subject.manifest(), "nonce": secrets.token_hex(16)}
        return {"subject_proof": subject.sign(body)}

    def redeem(self, credential, token, proof, now):
        with database(self.path) as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT token_hash, receipt FROM invitations WHERE id = ?", (credential,)).fetchone()
            if row is None or not hmac.compare_digest(row[0], hashlib.sha256(token).hexdigest()):
                raise Rejected("invitation-secret")
            if not isinstance(proof, dict) or set(proof) != {'subject_proof'}:
                raise Rejected('schema')
            body = typed_body(proof['subject_proof'], 'myterm-admission-reference-v0', [ADMISSION_FIELDS | {'credential'}])
            endpoint_manifest(body['subject'])
            if body["credential"] != credential:
                raise Rejected("invitation-binding")
            if row[1] is not None:
                receipt = json.loads(row[1])
                if receipt["approval"]["body"] != body:
                    raise Rejected("already-redeemed")
                return receipt
            with self.account.lock:
                self.account.current(self.role_key.public)
                registered = self.account.credential_current(credential, now, "single-use")
                if registered['public'] != self.role_key.public:
                    raise Rejected('invitation-binding')
                if body["account"] != self.account.anchor or body["issuer"] != self.role_key.public or body["subject"]["role"] != "server":
                    raise Rejected("invitation-binding")
                self.account.verify(body["subject"]["identity"], proof["subject_proof"])
                receipt = {"approval": self.role_key.sign(body), "subject_proof": proof["subject_proof"]}
            # The trusted issuer persists the unique allocation before returning its signed proof.
            db.execute("UPDATE invitations SET receipt = ? WHERE id = ? AND receipt IS NULL", (canonical(receipt), credential))
            return receipt


def rejects(operation, reason):
    try:
        operation()
    except Rejected as error:
        return str(error) == reason
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=Path, required=True)
    args = parser.parse_args()
    (args.binaries / "enrollment-results.json").unlink(missing_ok=True)
    identities, cases = [], []
    def identity(role):
        result = Identity(args.binaries, role); identities.append(result); return result
    try:
        first, authority = identity("client"), identity("server")
        server1, server2, late, fresh = [identity("server") for _ in range(4)]
        role = identity("credential")
        account = Account(first, authority)
        pinned = account.anchor
        repeated_genesis = Account(first, authority, pinned_anchor=pinned)
        check(repeated_genesis.anchor == account.anchor and repeated_genesis.head == account.head,
              'genesis anchor/checkpoint depend on canonical content rather than randomized signature bytes', cases)
        received = json.loads(canonical(account.genesis))
        check(Account(first, authority, pinned_anchor=pinned, received_genesis=received).anchor == pinned,
              'receiver accepts an externally supplied valid genesis under its existing anchor pin', cases)
        received['signature'] = '00' * 64
        check(rejects(lambda: Account(first, authority, pinned_anchor=pinned, received_genesis=received), 'genesis-signature'),
              'receiver rejects an externally supplied forged genesis signature', cases)
        check(authority.verifies(first.public, account.genesis), "native signature verifies first-client genesis fixture", cases)
        impostor = identity("client")
        check(rejects(lambda: Account(impostor, authority, pinned_anchor=pinned), "account-anchor"),
              "relay-substituted first-client account anchor rejected", cases)
        check(len({i.public for i in identities}) == len(identities), "independent endpoint signing identities are distinct", cases)
        changed_manifest = account.approve(authority, first)
        altered = json.loads(canonical(changed_manifest['approval']['body']))
        altered['subject']['directory_recipient'] = authority.recipient.public
        changed_manifest = {'approval': authority.sign(altered), 'subject_proof': first.sign(altered)}
        check(rejects(lambda: account.accept_approval(changed_manifest), 'subject-binding'),
              'existing endpoint key-purpose binding cannot be silently replaced by admission replay', cases)
        grant = account.credential(first, role, expires=100, now=1, mode="reusable")
        role.role = 'server'
        try:
            aliased_identity = account.enrollment(grant, role, role, claimed_time=2)
        finally:
            role.role = 'credential'
        check(rejects(lambda: account.accept_enrollment(aliased_identity, now=2), 'credential-key-is-not-endpoint'),
              'a reusable credential key cannot be reused as a server instance identity', cases)
        check(role.recipient.public in account.directory_recipients(2),
              'active account-owned credential is an authorized directory bootstrap recipient', cases)
        offline1 = account.enrollment(grant, role, server1, claimed_time=10)
        offline2 = account.enrollment(grant, role, server2, claimed_time=11)
        offline_client = identity('client')
        server_cache, client_cache = CachedTrust(account, server1), CachedTrust(account, offline_client)
        original_sign, original_verify = authority.sign, authority.verifies
        def unavailable(*_args, **_kwargs):
            raise RuntimeError('offline phase contacted old authority')
        authority.sign = unavailable; authority.verifies = unavailable
        try:
            check(server_cache.recognize(offline1, now=12) == server1.public,
                  'new server verifies offline delegation without any old-authority crypto call', cases)
            new_client_approval = server_cache.approve(server1, offline_client)
            client_cache.recognize(offline1, now=12)
            client_cache.accept_approval(new_client_approval)
            check(offline_client.public in client_cache.members and server1.public not in account.members,
                  'offline-enrolled server can approve a client using cached trust without canonical registration', cases)
        finally:
            authority.sign, authority.verifies = original_sign, original_verify
        check(rejects(lambda: account.accept_approval(new_client_approval), 'removed-or-unknown-issuer'),
              'a derived-only endpoint certificate is not independent canonical authority without its admission chain', cases)
        changed_binding = json.loads(canonical(offline1))
        for field in ('delegation', 'subject_proof'):
            changed_binding[field]['body']['subject']['directory_recipient'] = server2.recipient.public
        check(rejects(lambda: account.accept_enrollment(changed_binding, now=12), "signature"),
              "substituting recipient key invalidates native signed endpoint binding", cases)
        check(server1.public not in account.members and server2.public not in account.members,
              "offline delegation proofs are created without contacting authority", cases)
        check(account.accept_enrollment(offline1, now=12) == server1.public,
              "valid reusable deployment proof accepted with bound native identity/envelope keys", cases)
        check(account.accept_enrollment(offline2, now=13) == server2.public,
              "same reusable credential enrolls a distinct server identity", cases)
        witnessed, rejected_witnessed = identity('server'), identity('server')
        witnessed_proof = account.enrollment(grant, role, witnessed, claimed_time=19)
        rejected_witnessed_proof = account.enrollment(grant, role, rejected_witnessed, claimed_time=19)
        witness_cache = CachedTrust(account, server2)
        independent_admission = witness_cache.certify_enrollment(witnessed_proof, witnessed, now=20)
        doomed_cache = CachedTrust(account, server1)
        removed_issuer_admission = doomed_cache.certify_enrollment(rejected_witnessed_proof, rejected_witnessed, now=21)
        client_attempt = account.enrollment(grant, role, impostor, claimed_time=10)
        check(rejects(lambda: account.accept_enrollment(client_attempt, now=14), "server-only"),
              "server-enrollment delegation cannot directly approve a client", cases)
        check(rejects(lambda: account.remove(role, server1.public), "removed-or-unknown-issuer"),
              "credential key cannot directly remove an account endpoint", cases)
        account.remove(authority, first.public)
        check(first.recipient.public not in account.directory_recipients(16)
              and role.recipient.public in account.directory_recipients(16),
              'device removal excludes its key while preserving independent account-owned credential', cases)
        check(account.anchor == pinned, "account anchor survives removal of first client", cases)
        check(server1.public in account.members and server2.public in account.members,
              "ordinary creator removal preserves already enrolled servers", cases)
        created_later = account.enrollment(grant, role, fresh, claimed_time=15)
        check(account.accept_enrollment(created_later, now=16) == fresh.public,
              "account-owned deployment credential survives creator removal", cases)
        check(account.accept_enrollment(offline1, now=101) == server1.public,
              "recognized server does not inherit enrollment credential expiry", cases)
        check(role.recipient.public not in account.directory_recipients(101)
              and server1.recipient.public in account.directory_recipients(101),
              'expired credential stops receiving fresh content keys while its recognized server still receives them', cases)
        saved_sign = server2.sign
        server2.sign = unavailable
        try:
            stored_admission = witness_cache.certify_enrollment(witnessed_proof, witnessed, now=101)
            check(stored_admission == independent_admission,
                  'late forwarding reuses the original admission without a new post-expiry signature', cases)
        finally:
            server2.sign = saved_sign
        account.accept_approval(stored_admission)
        check(witnessed.public in account.members,
              'already-issued independent admission stays valid after credential expiry while issuer remains current', cases)
        late_proof = account.enrollment(grant, role, late, claimed_time=17)
        check(rejects(lambda: account.accept_enrollment(late_proof, now=101), "fresh-approval-required"),
              "unseen offline enrollment first seen after expiry requires fresh approval", cases)
        approval = account.approve(authority, late); account.accept_approval(approval)
        check(late.public in account.members, "current trusted endpoint can freshly approve late server", cases)
        second_role = identity("credential")
        second_grant = account.credential(authority, second_role, expires=200, now=110, mode="reusable")
        unseen = identity("server")
        unseen_proof = account.enrollment(second_grant, second_role, unseen, claimed_time=111)
        recognized = identity("server")
        recognized_proof = account.enrollment(second_grant, second_role, recognized, claimed_time=111)
        check(account.accept_enrollment(recognized_proof, now=111) == recognized.public,
              "another credential's server is recognized before revocation", cases)
        account.revoke_credential(authority, second_grant)
        check(second_role.recipient.public not in account.directory_recipients(112)
              and recognized.recipient.public in account.directory_recipients(112),
              'credential revocation filters future envelope recipients without cascading to its recognized server', cases)
        check(rejects(lambda: account.accept_enrollment(unseen_proof, now=112), "fresh-approval-required"),
              "unseen enrollment presented after credential revocation requires fresh approval", cases)
        check(account.accept_enrollment(recognized_proof, now=112) == recognized.public,
              "credential revocation preserves the server it already enrolled", cases)
        # Finalized admission outlives its admitting endpoint; unseen old authority does not.
        newcomer = identity("client")
        before = account.approve(server1, newcomer); account.accept_approval(before)
        unrecorded = identity("client")
        uncertain = account.approve(server1, unrecorded)
        account.remove(authority, server1.public)
        check(rejects(lambda: account.accept_approval(removed_issuer_admission), 'removed-or-unknown-issuer'),
              'removed issuer cannot rescue an unrecorded admission with a claimed earlier time', cases)
        check(newcomer.public in account.members, "ordered admission survives ordinary removal of its approver", cases)
        check(rejects(lambda: account.accept_approval(uncertain), "removed-or-unknown-issuer"),
              "unrecorded admission from removed issuer requires reapproval", cases)
        check(rejects(lambda: account.accept_enrollment(offline1, now=20), "explicit-reapproval-required"),
              "removed server cannot silently rejoin using old enrollment evidence", cases)
        # A dedicated trusted issuer allocates one generic invitation using an actual SQLite transaction.
        with tempfile.TemporaryDirectory(prefix="single-use-", dir=args.binaries) as scratch:
            issuer = SingleUseIssuer(account, authority, Path(scratch) / "issuer.sqlite")
            oracle_invitation, oracle_token = issuer.issue(authority, now=120, expires=150)
            invitation, token = issuer.issue(authority, now=120, expires=150)
            x, y = identity("server"), identity("server")
            ordinary = issuer.request(oracle_invitation, x)['subject_proof']['body']
            wrong_domain = json.loads(canonical(ordinary)); wrong_domain['domain'] = 'myterm-account-commit-reference-v0'
            check(rejects(lambda: issuer.redeem(oracle_invitation, oracle_token, {'subject_proof': x.sign(wrong_domain)}, 121), 'domain'),
                  'single-use issuer rejects cross-purpose signing-oracle request', cases)
            extra_fields = json.loads(canonical(ordinary)); extra_fields['target'] = authority.public
            check(rejects(lambda: issuer.redeem(oracle_invitation, oracle_token, {'subject_proof': x.sign(extra_fields)}, 121), 'schema'),
                  'single-use issuer refuses extra signed administrative fields', cases)
            xp = issuer.request(invitation, x)
            yp = issuer.request(invitation, y)
            barrier = threading.Barrier(2)
            def attempt(proof):
                barrier.wait(timeout=10)
                try:
                    issuer.redeem(invitation, token, proof, now=122); return "accepted"
                except Rejected as error:
                    return str(error)
            with ThreadPoolExecutor(max_workers=2) as workers:
                results = list(workers.map(attempt, [xp, yp]))
            check(sorted(results) == ["accepted", "already-redeemed"],
                  "concurrent generic single-use redemption allocates exactly one subject", cases)
            winner = xp if results[0] == "accepted" else yp
            receipt = issuer.redeem(invitation, token, winner, now=123)
            check(issuer.redeem(invitation, token, winner, now=123) == receipt,
                  "same single-use subject retry returns original signed allocation", cases)
            check(rejects(lambda: issuer.redeem(invitation, secrets.token_bytes(32), winner, now=123), "invitation-secret"),
                  "relay guessing cannot replace the invitation secret", cases)
            loser, loser_actor = (yp, y) if results[0] == 'accepted' else (xp, x)
            fake_approval = {'approval': loser_actor.sign(loser['subject_proof']['body']), 'subject_proof': loser['subject_proof']}
            check(rejects(lambda: account.accept_approval(fake_approval), 'signature'),
                  "losing subject cannot forge the trusted issuer's allocation signature", cases)
            check(issuer.redeem(invitation, token, winner, now=151) == receipt,
                  "already verified single-use allocation survives invitation expiry", cases)
            expired, exp_token = issuer.issue(authority, now=120, expires=121)
            exp_proof = issuer.request(expired, x)
            check(rejects(lambda: issuer.redeem(expired, exp_token, exp_proof, now=122), "fresh-approval-required"),
                  "unredeemed generic invitation expires at trusted issuer", cases)
            wrong_mode = account.enrollment(invitation, authority, y, claimed_time=123)
            check(rejects(lambda: account.accept_enrollment(wrong_mode, now=124), 'credential-mode'),
                  'single-use invitation cannot be presented on reusable-delegation route', cases)
            account.accept_approval(receipt)
            reused = receipt['approval']['body']['subject']['identity']
            check(reused in account.members, "trusted single-use allocation admits its bound server", cases)
        check(all(authority.verifies(authority.public, event) for event in account.events),
              "native signatures verify reference-model membership records", cases)
        size_before = len(account.events)
        check(rejects(lambda: account.revoke_credential(authority, 'ff'*16), 'unknown-credential') and len(account.events) == size_before,
              'unknown credential revocation leaves no committed event', cases)
        check(rejects(lambda: account.credential_current('ff'*16, 10, 'reusable'), 'unknown-credential'),
              'unknown credential is rejected explicitly', cases)
        check(rejects(lambda: account.approve(authority, role), 'endpoint-role'),
              'credential-role identity cannot be admitted as an endpoint', cases)
        check(rejects(lambda: account.credential(authority, role, expires=float('inf'), now=130, mode='reusable'), 'credential-policy'),
              'deployment credentials require a finite bounded expiry', cases)
        check(rejects(lambda: account.credential(authority, authority, expires=200, now=130, mode='reusable'), 'credential-key-purpose'),
              'reusable delegation uses dedicated role keys rather than cloning an endpoint key', cases)
        with tempfile.TemporaryDirectory(prefix='other-issuer-', dir=args.binaries) as scratch:
            other_issuer = SingleUseIssuer(account, server2, Path(scratch) / 'issuer.sqlite')
            other_issuer.issue(authority, now=130, expires=200)
            account.remove(authority, server2.public)
            check(server2.recipient.public not in account.directory_recipients(131),
                  'a live single-use invitation cannot preserve a removed issuer as a directory recipient', cases)
        report = {"generated_at": datetime.now(timezone.utc).isoformat(), "passed": sum(c['passed'] for c in cases),
                  "total": len(cases), "cases": cases,
                  "limitations": ["Policy/clock and membership ledger run in Python with native CryptoKit signatures; not the production Rust membership engine",
                                  "Genesis, authority designation and endpoint-key association are local fixtures, not a live passkey/enrollment ceremony",
                                  "Reusable offline proof creation is exercised; actual offline local/direct authorization/channel integration is not implemented",
                                  "Canonical credential issuance requires the reference authority before offline use; issuer discovery/availability workflow is not implemented",
                                  "Single-use transaction assumes one honest trusted issuer with its current SQLite state; rollback/cloning/malicious issuer not solved",
                                  "Single-use allocation is persisted before return, but no issuer-process/power-loss recovery or real enrollment network protocol is tested",
                                  "Credential handoff/storage and distribution of directory keys to deployment capabilities are not implemented",
                                  "No full recursive provisional-admission propagation, signed receipt replay/fork client implementation or secure account-state keystore",
                                  "No specialist audit or full composed-protocol security approval"]}
        (args.binaries / 'enrollment-results.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps({"enrollment_checks_passed": report['passed'], "total": report['total']}))
    finally:
        for actor in identities:
            actor.close()


if __name__ == '__main__':
    main()
