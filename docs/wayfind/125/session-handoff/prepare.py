"""Build disposable native binaries using the immutable checkpoint foundation."""
import argparse
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REVISION = "ab4f866153ff46c03e1e51de72eec8d85d233d51"


def command(args, log, env=None):
    with log.open("w") as output:
        subprocess.run(args, stdout=output, stderr=subprocess.STDOUT, check=True, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-source", type=Path, required=True,
                        help="Unmodified source directory produced by the retained run.py")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--resume", action="store_true", help="Rebuild this experiment's scratch sources")
    parser.add_argument("--release", action="store_true", help="Optimize binaries for timed workloads")
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=args.resume)
    foundation = out / "foundation"
    foundation.mkdir(exist_ok=args.resume)
    files = subprocess.check_output(["git", "ls-tree", "-r", "--name-only", REVISION,
                                     "script/wezterm-feasibility"], cwd=ROOT, text=True).splitlines()
    for name in files:
        (foundation / Path(name).name).write_bytes(subprocess.check_output(
            ["git", "show", f"{REVISION}:{name}"], cwd=ROOT))
    sys.path.insert(0, str(foundation))
    spec = importlib.util.spec_from_file_location("checkpoint", foundation / "checkpoint.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT = ROOT
    if not args.resume:
        module.prepare(args.baseline_source.resolve(), out / "native")
    native = out / "native"
    main_rs = native / "probe/main.rs"
    text = main_rs.read_text()
    if 'mod handoff;' not in text:
        text = text.replace('if std::env::args().any(|a|a == "--live-pty")',
                            'if std::env::args().any(|a|a == "--handoff") {handoff::run()} else if std::env::args().any(|a|a == "--live-pty")')
        main_rs.write_text(text + '\nmod handoff;\n')
    shutil.copyfile(HERE / "server.rs", native / "probe/handoff.rs")
    manifest = native / "probe/Cargo.toml"
    if 'rustls =' not in manifest.read_text():
        manifest.write_text(manifest.read_text().replace('[dependencies]', '''[dependencies]
rustls = { version = "=0.23.46", default-features = false, features = ["ring", "std", "tls12"] }
rcgen = "=0.14.9"
base64 = "=0.22.1"
'''))
    if (HERE / "Cargo.lock").exists():
        shutil.copyfile(HERE / "Cargo.lock", native / "probe/Cargo.lock")
    # APFS clones reuse dependency artifacts without changing retained baseline binaries.
    target = out / "cargo-target"
    if not target.exists():
        subprocess.run(["cp", "-cR", str(args.baseline_source.resolve().parent / "probe/target"), str(target)], check=True)
    env = dict(os.environ, CARGO_TARGET_DIR=str(target))
    profile = "release" if args.release else "debug"
    flags = ["--release"] if args.release else []
    command(["cargo", "+1.99.1", "build", "--locked", "--offline", *flags, "--manifest-path", str(manifest)], out / "rust-build.log", env)
    shutil.copyfile(Path(env["CARGO_TARGET_DIR"]) / profile / "wezterm-feasibility", out / "server")
    (out / "server").chmod(0o755)
    shutil.copyfile(native / "probe/Cargo.lock", out / "Cargo.lock")
    # The existing prefix supplies real native state inspection and cell geometry.
    driver = native / "swift-probe/Sources/Baseline/main.swift"
    prefix = (ROOT / "script/native-comparison/swift/Sources/Baseline/main.swift").read_text().split("@MainActor\nfunc run() throws")[0]
    prefix = prefix.replace("var replies: [UInt8] = []", "var replies: [UInt8] = []; var suppressed = true; var suppressedBytes = 0; var onUserInput: ((ArraySlice<UInt8>) -> Void)?")
    prefix = prefix.replace("replies.append(contentsOf: data)", "if suppressed { suppressedBytes += data.count } else { onUserInput?(data) }")
    prefix = prefix.replace('cols: 20, rows: 6', 'cols: 120, rows: 40')
    prefix = prefix.replace('return view', 'view.getTerminal().changeScrollback(40)\n    return view')
    driver.write_text(prefix + (HERE / "client.swift").read_text().replace("let driver = ClientDriver()", (HERE / "gui.swift").read_text() + "\nlet driver = ClientDriver()"))
    command(["swift", "build", "--package-path", str(native / "swift-probe"),
             "-c", "release" if args.release else "debug",
             "--scratch-path", str(native / "swift-build")], out / "swift-build.log")
    shutil.copyfile(native / f"swift-build/{profile}/Baseline", out / "client")
    (out / "client").chmod(0o755)
    bundle = out / "HandoffReview.app/Contents"
    (bundle / "MacOS").mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out / "client", bundle / "MacOS/HandoffReview")
    import plistlib
    with (bundle / "Info.plist").open("wb") as info:
        plistlib.dump({"CFBundlePackageType": "APPL", "CFBundleExecutable": "HandoffReview",
            "CFBundleIdentifier": "com.gordonbeeming.myterm.handoff-prototype", "CFBundleName": "MyTerm handoff prototype",
            "LSMinimumSystemVersion": "14.0", "NSPrincipalClass": "NSApplication"}, info)
    (out / "build.json").write_text(json.dumps({"foundation": REVISION, "root": str(ROOT), "profile": profile,
        "sources": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in HERE.iterdir() if p.suffix in (".py", ".swift", ".rs")},
        "binaries": {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in ("server", "client")}}, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
