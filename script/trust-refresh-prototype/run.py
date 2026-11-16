#!/usr/bin/env python3
"""Build and exercise disposable native TLS refresh probes on macOS."""
import argparse
import hashlib
import io
import json
import platform
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COMMIT = "0131ae9d78e42fcc2c1811315e62410ad96d8230"
ARCHIVE_HASH = "893e755fe720627769d7bd49d15815e86cc0fd4a4ae84b3717caf6fce4255bb4"


def build(out, archive):
    if archive is None:
        data = subprocess.check_output([
            "curl", "--fail", "--location", "--silent", "--show-error", "--proto", "=https", "--proto-redir", "=https",
            "--max-filesize", "100000000", "--max-time", "120",
            f"https://codeload.github.com/google/boringssl/tar.gz/{COMMIT}",
        ], timeout=130)
        if len(data) > 100_000_000:
            raise RuntimeError("dependency archive exceeds fixture bound")
    else:
        data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != ARCHIVE_HASH:
        raise RuntimeError("BoringSSL archive digest mismatch")

    with tempfile.TemporaryDirectory(prefix="verified-source-", dir=out) as scratch:
        scratch = Path(scratch)
        with tarfile.open(fileobj=io.BytesIO(data)) as source_archive:
            source_archive.extractall(scratch, filter="data")
        source = scratch / f"boringssl-{COMMIT}"
        native = scratch / "build"
        commands = [
            ["cmake", "-S", source, "-B", native, "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_TESTING=OFF"],
            ["cmake", "--build", native, "--target", "ssl", "--parallel", "6"],
            ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-pthread", "-I", source / "include",
             "-c", ROOT / "channel.c", "-o", out / "channel.o"],
            ["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2", "-I", source / "include",
             "-c", ROOT / "removal-signatures.c", "-o", out / "removal-signatures.o"],
            ["swiftc", "-O", "-import-objc-header", ROOT / "channel.h", ROOT / "channel-client.swift",
             out / "channel.o", native / "libssl.a", native / "libcrypto.a", "-lc++", "-o", out / "channel-client"],
            ["rustc", "--edition=2021", "-O", ROOT / "channel-server.rs",
             "-C", f"link-arg={out / 'channel.o'}", "-C", f"link-arg={out / 'removal-signatures.o'}",
             "-L", native, "-l", "static=ssl", "-l", "static=crypto", "-l", "c++", "-o", out / "channel-server"],
        ]
        with (out / "build.log").open("w") as log:
            for command in commands:
                subprocess.run([str(arg) for arg in command], stdout=log, stderr=subprocess.STDOUT,
                               check=True, timeout=600)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="new disposable results directory")
    parser.add_argument("--archive", type=Path, help="optional previously downloaded pinned source archive")
    parser.add_argument("--cycles", type=int, default=100)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("this native Swift/CryptoKit probe currently requires macOS")
    if not 1 <= args.cycles <= 10000:
        parser.error("--cycles must be between 1 and 10000")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    provenance = {
        "dependency_commit": COMMIT, "dependency_archive_sha256": ARCHIVE_HASH,
        "source_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(ROOT.iterdir()) if p.suffix in (".py", ".c", ".h", ".rs", ".swift")},
        "environment": {"system": platform.platform(), "machine": platform.machine(),
                        "python": platform.python_version()},
    }
    for tool in ("swiftc", "rustc", "clang", "cmake"):
        provenance["environment"][tool] = subprocess.check_output(
            [tool, "--version"], text=True, stderr=subprocess.STDOUT, timeout=30
        ).strip()
    build(out, args.archive)
    for name, expected in provenance["source_sha256"].items():
        if hashlib.sha256((ROOT / name).read_bytes()).hexdigest() != expected:
            raise RuntimeError("source changed during build: " + name)
    provenance["binary_sha256"] = {
        name: hashlib.sha256((out / name).read_bytes()).hexdigest()
        for name in ("channel-client", "channel-server", "channel.o", "removal-signatures.o")
    }
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    subprocess.run([sys.executable, "-B", str(ROOT / "checks.py"), "--binaries", str(out),
                    "--cycles", str(args.cycles)], check=True)


if __name__ == "__main__":
    main()
