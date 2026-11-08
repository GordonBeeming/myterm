#!/usr/bin/env python3
"""Throwaway native SPAKE2 interoperability checks; not a complete admission protocol."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import secrets
import selectors
import subprocess
import sys
import tarfile
import tempfile
import time

COMMIT = "0131ae9d78e42fcc2c1811315e62410ad96d8230"
ARCHIVE_HASH = "893e755fe720627769d7bd49d15815e86cc0fd4a4ae84b3717caf6fce4255bb4"
ROOT = Path(__file__).resolve().parent


def command(args):
    subprocess.run([str(x) for x in args], check=True, timeout=600)


def build(deps, out):
    archive = deps / "boringssl.tar.gz"
    archive_bytes = archive.read_bytes()
    if hashlib.sha256(archive_bytes).hexdigest() != ARCHIVE_HASH:
        raise RuntimeError("BoringSSL archive digest mismatch")
    # Re-extract the checked archive into a fresh owned tree and build that exact source.
    with tempfile.TemporaryDirectory(prefix="verified-boringssl-", dir=out) as scratch:
        verified = Path(scratch)
        with tarfile.open(fileobj=io.BytesIO(archive_bytes)) as t:
            t.extractall(verified, filter="data")
        source = verified / f"boringssl-{COMMIT}"
        build_dir = verified / "build"
        with (out / "dependency-build.log").open("w") as log:
            subprocess.run(["cmake", "-S", str(source), "-B", str(build_dir),
                            "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
            subprocess.run(["cmake", "--build", str(build_dir), "--target", "ssl", "--parallel", "6"],
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=600)
        library = build_dir / "libcrypto.a"
        build_callers(source, library, out)


def build_callers(source, library, out):
    command(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-I", source / "include",
             "-c", ROOT / "directory.c", "-o", out / "directory.o"])
    command(["swiftc", "-O", ROOT / "directory-sender.swift", "-o", out / "directory-sender"])
    command(["rustc", "--edition=2021", "-O", ROOT / "directory-recipient.rs",
             "-C", f"link-arg={out / 'directory.o'}", "-L", library.parent,
             "-l", "static=crypto", "-l", "c++", "-o", out / "directory-recipient"])
    command(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-pthread", "-I", source / "include",
             "-c", ROOT / "channel.c", "-o", out / "channel.o"])
    command(["swiftc", "-O", "-import-objc-header", ROOT / "channel.h", ROOT / "channel-client.swift",
             out / "channel.o", library.parent / "libssl.a", library, "-lc++", "-o", out / "channel-client"])
    command(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-I", source / "include",
             "-c", ROOT / "removal-signatures.c", "-o", out / "removal-signatures.o"])
    command(["rustc", "--edition=2021", "-O", ROOT / "channel-server.rs",
             "-C", f"link-arg={out / 'channel.o'}", "-C", f"link-arg={out / 'removal-signatures.o'}",
             "-L", library.parent, "-l", "static=ssl", "-l", "static=crypto", "-l", "c++",
             "-o", out / "channel-server"])
    command(["swiftc", "-O", "-import-objc-header", ROOT / "removal-signatures.h",
             ROOT / "revocation-order.swift", out / "removal-signatures.o", library,
             "-lc++", "-o", out / "revocation-order"])
    command(["swiftc", "-O", ROOT / "ordering-client.swift", "-o", out / "ordering-client"])
    command(["rustc", "--edition=2021", "-O", ROOT / "ordering-server.rs",
             "-C", f"link-arg={out / 'removal-signatures.o'}", "-L", library.parent,
             "-l", "static=crypto", "-l", "c++", "-o", out / "ordering-server"])
    command(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-I", source / "include",
             "-c", ROOT / "bridge.c", "-o", out / "bridge.o"])
    command(["ar", "rcs", out / "libmyterm_pake.a", out / "bridge.o"])
    command(["swiftc", "-O", "-import-objc-header", ROOT / "bridge.h", ROOT / "new-client.swift",
             "-L", out, "-lmyterm_pake", library, "-lc++", "-o", out / "new-client"])
    command(["rustc", "--edition=2021", "-O", ROOT / "approver.rs", "-L", out,
             "-L", library.parent, "-l", "static=crypto", "-l", "c++", "-o", out / "approver"])


class Endpoint:
    def __init__(self, path, code, binding, fixture_clock=False, begin=True):
        argv = [str(path)] + (["--fixture-clock"] if fixture_clock else [])
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0)
        self.buffer = b""
        self.send(code)
        self.send(binding)
        if path.name == "approver" and begin:
            self.send("BEGIN")

    def send(self, line):
        self.process.stdin.write((line + "\n").encode("ascii"))
        self.process.stdin.flush()

    def receive(self):
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(timeout=remaining):
                    raise RuntimeError("native endpoint did not respond")
                chunk = os.read(self.process.stdout.fileno(), 8192)
                if not chunk:
                    raise RuntimeError("native endpoint exited before response")
                self.buffer += chunk
                if len(self.buffer) > 8192:
                    raise RuntimeError("native endpoint response exceeded fixture limit")
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line.decode("ascii")

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        for stream in (self.process.stdin, self.process.stdout):
            stream.close()


def request_checks(out):
    cases = []
    for seconds, rejected in ((299, False), (300, True)):
        b = Endpoint(out / "approver", "disposable-test-code", "expiry-fixture", fixture_clock=True, begin=False)
        try:
            b.send(f"ADVANCE {seconds}")
            if b.receive() != "ADVANCED":
                raise RuntimeError("fixture clock did not advance")
            b.send("BEGIN")
            reply = b.receive()
            cases.append({"name": f"request begin at {seconds} seconds (injected clock)",
                          "passed": (reply == "REJECT") == rejected})
        finally:
            b.close()
    b = Endpoint(out / "approver", "disposable-correct-code", "attempt-fixture", begin=False)
    try:
        for i in range(5):
            b.send("BEGIN")
            a = Endpoint(out / "new-client", "disposable-wrong-code", "attempt-fixture")
            try:
                am, bm = a.receive(), b.receive()
                a.send(bm); b.send(am)
                ap, bp = a.receive(), b.receive()
                a.send(bp); b.send(ap)
                av, bv = a.receive(), b.receive()
                if av != "REJECT" or bv != "REJECT":
                    raise RuntimeError(f"wrong-code attempt {i + 1} was not rejected")
            finally:
                a.close()
        b.send("BEGIN")
        cases.append({"name": "five wrong attempts exhaust request", "passed": b.receive() == "REJECT"})
    finally:
        b.close()
    b = Endpoint(out / "approver", "disposable-correct-code", "single-use-fixture")
    a = Endpoint(out / "new-client", "disposable-correct-code", "single-use-fixture")
    try:
        am, bm = a.receive(), b.receive()
        a.send(bm); b.send(am)
        ap, bp = a.receive(), b.receive()
        a.send(bp); b.send(ap)
        if a.receive() != "PEER_VERIFIED" or b.receive() != "PEER_VERIFIED":
            raise RuntimeError("single-use setup did not verify peers")
        b.send("BEGIN")
        cases.append({"name": "verified request refuses reuse", "passed": b.receive() == "REJECT"})
    finally:
        a.close(); b.close()
    return cases


def exchange(out, fixture, mutation=None, old_message=None, old_proof=None):
    # All secrets are disposable, in memory and pipe input only. Never include them in results.
    code, binding = fixture
    peer_binding = binding
    if mutation in ("account substitution", "endpoint key substitution", "approver key substitution", "request substitution", "role substitution"):
        changed = json.loads(binding)
        field = {"account substitution": "account_anchor", "endpoint key substitution": "new_public_key",
                 "approver key substitution": "approver_public_key", "request substitution": "request",
                 "role substitution": "role"}[mutation]
        changed[field] = "server" if field == "role" else secrets.token_hex(32)
        peer_binding = json.dumps(changed, sort_keys=True, separators=(",", ":"))
    peer_code = code if mutation != "wrong code" else str((int(code) + 1) % 10**8).zfill(8)
    a = Endpoint(out / "new-client", code, binding)
    b = Endpoint(out / "approver", peer_code, peer_binding)
    start = time.perf_counter_ns()
    try:
        am, bm = a.receive(), b.receive()
        a.send(bm)
        b.send(old_message if mutation == "replayed exchange" else am)
        ap, bp = a.receive(), b.receive()
        a.send(ap if mutation == "reflected confirmation" else bp)
        b.send(old_proof if mutation == "replayed confirmation" else ap)
        av, bv = a.receive(), b.receive()
        return {"new_client": av, "approver": bv,
                "exchange_ms": (time.perf_counter_ns() - start) / 1e6}, am, ap
    finally:
        a.close()
        b.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    for name in ("results.json", "revocation-order-results.json", "ordering-results.json", "channel-results.json", "directory-results.json", "enrollment-results.json"):
        (args.output / name).unlink(missing_ok=True)
    build(args.deps.resolve(), args.output.resolve())
    cases = []
    fixture = (str(secrets.randbelow(10**8)).zfill(8),
               json.dumps({"account_anchor": secrets.token_hex(32), "request": secrets.token_hex(16),
                           "role": "client", "new_public_key": secrets.token_hex(32),
                           "approver_public_key": secrets.token_hex(32)}, sort_keys=True, separators=(",", ":")))
    happy, old_message, old_proof = exchange(args.output, fixture)
    cases.append({"name": "matching secret and transcript", **happy,
                  "passed": happy["new_client"] == happy["approver"] == "PEER_VERIFIED"})
    for mutation in ("wrong code", "account substitution", "endpoint key substitution", "approver key substitution", "request substitution", "role substitution",
                     "replayed exchange", "reflected confirmation", "replayed confirmation"):
        result, _, _ = exchange(args.output, fixture, mutation, old_message, old_proof)
        # Each attack must at least stop the attacked peer from completing mutual confirmation.
        expected_pair = ("REJECT", "PEER_VERIFIED") if mutation == "reflected confirmation" else (
                        ("PEER_VERIFIED", "REJECT") if mutation == "replayed confirmation" else ("REJECT", "REJECT"))
        expected = (result["new_client"], result["approver"]) == expected_pair
        cases.append({"name": mutation, **result, "passed": expected})
    for binary in ("new-client", "approver"):
        e = Endpoint(args.output / binary, "disposable-test-code", "fixture-context")
        try:
            e.receive()
            e.send("not-hex")
            verdict = e.receive()
            cases.append({"name": f"non-hex exchange message to {binary}", "passed": verdict == "REJECT"})
        finally:
            e.close()
    cases.extend(request_checks(args.output))
    for binary in ("new-client", "approver"):
        result = subprocess.run([str(args.output / binary)], input=b"bad\x00code\nfixture-context\nBEGIN\n",
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
        cases.append({"name": f"NUL-containing input rejected by {binary}",
                      "passed": result.stdout == b"REJECT\n" and result.returncode != 0})
    order_report = json.loads(subprocess.check_output([str(args.output / "revocation-order")], text=True, timeout=10))
    if not order_report["sameSignedBytes"] or not all(c["passed"] for c in order_report["checks"]):
        raise RuntimeError("signed-history counterexample checks failed")
    (args.output / "revocation-order-results.json").write_text(json.dumps(order_report, indent=2) + "\n")
    command([sys.executable, ROOT / "ordering_checks.py", "--binaries", args.output.resolve()])
    ordering_report = json.loads((args.output / "ordering-results.json").read_text())
    command([sys.executable, ROOT / "channel_checks.py", "--binaries", args.output.resolve()])
    channel_report = json.loads((args.output / "channel-results.json").read_text())
    command([sys.executable, ROOT / "directory_checks.py", "--binaries", args.output.resolve()])
    directory_report = json.loads((args.output / "directory-results.json").read_text())
    command([sys.executable, ROOT / "enrollment_checks.py", "--binaries", args.output.resolve()])
    enrollment_report = json.loads((args.output / "enrollment-results.json").read_text())
    report = {"prototype": "SPAKE2 draft-02 shared BoringSSL core, Swift and Rust callers",
              "generated_at": datetime.now(timezone.utc).isoformat(),
              "boringssl_commit": COMMIT, "archive_sha256": ARCHIVE_HASH,
              "toolchains": {tool: subprocess.check_output([tool, "--version"], text=True).splitlines()[0]
                             for tool in ("clang", "swiftc", "rustc", "cmake")},
              "platform": platform.platform(), "architecture": platform.machine(),
              "ordering": {"passed": ordering_report["passed"], "total": ordering_report["total"]},
              "channels": {"passed": channel_report["passed"], "total": channel_report["total"]},
              "directory": {"passed": directory_report["passed"], "total": directory_report["total"]},
              "enrollment_reference": {"passed": enrollment_report["passed"], "total": enrollment_report["total"]},
              "signed_history_counterexample": {"passed": sum(c["passed"] for c in order_report["checks"]),
                                                "total": len(order_report["checks"]),
                                                "same_signed_bytes": order_report["sameSignedBytes"]},
              "cases": cases, "passed": sum(c["passed"] for c in cases), "total": len(cases),
              "limitations": ["Approval primitive alone grants no membership; separate ordering and TLS probes are not an integrated account protocol",
                              "Request state is per-process and in-memory; no durable admission or request recovery",
                              "Public-key fields are transcript fixtures, not generated endpoint identities",
                              "Shared C core: this is FFI interoperability, not independent implementations",
                              "No independent audit of the composed approval ceremony"]}
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if report["passed"] != report["total"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
