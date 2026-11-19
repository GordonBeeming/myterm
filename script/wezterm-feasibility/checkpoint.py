"""Native, scratch-only cross-engine checkpoint experiment. No production or GUI."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil

from run import ROOT, WEZTERM, FINL, run

HERE = Path(__file__).resolve().parent


def replace_once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise RuntimeError(f"scratch source shape changed: {path}: {old[:60]}")
    path.write_text(text.replace(old, new))


def prepare(source, out):
    out.mkdir(parents=True)
    run(["cp", "-cR", str(source), str(out / "source")], out / "copy.log")
    scratch = out / "source"
    run(["patch", "--batch", "--forward", "-p1", "-d", str(scratch), "-i",
         str(HERE / "wezterm-compatibility.patch")], out / "compatibility-patch.log")
    from checkpoint_compatibility import extend
    extend(scratch, replace_once)
    replace_once(scratch / "vtparse/src/lib.rs", "impl VTParser {",
                 "impl VTParser {\n    pub fn prototype_is_ground(&self) -> bool { self.state == State::Ground }\n")
    replace_once(scratch / "wezterm-escape-parser/src/parser/mod.rs", "impl Parser {",
                 "impl Parser {\n    pub fn prototype_is_ground(&self) -> bool { self.state_machine.prototype_is_ground() }\n")
    terminal = scratch / "term/src/terminal.rs"
    replace_once(terminal, "    parser: Parser,", "    parser: Parser,\n    prototype_pending: Vec<u8>,\n    prototype_overflow: bool,")
    replace_once(terminal, "            parser: Parser::new(),",
                 "            parser: Parser::new(),\n            prototype_pending: vec![],\n            prototype_overflow: false,")
    replace_once(terminal, "            self.parser.parse(bytes, |action| performer.perform(action));", """
            for byte in bytes {
                if self.prototype_pending.len() < 16384 { self.prototype_pending.push(*byte); }
                else { self.prototype_overflow = true; }
                self.parser.parse(&[*byte], |action| performer.perform(action));
                if self.parser.prototype_is_ground() {
                    self.prototype_pending.clear(); self.prototype_overflow = false;
                }
            }
""")
    with terminal.open("a") as f:
        f.write('''
impl Terminal {
    pub fn prototype_checkpoint(&self, sequence: usize) -> anyhow::Result<Vec<u8>> {
        anyhow::ensure!(!self.prototype_overflow, "checkpoint unfinished-token limit");
        let p = &self.prototype_pending;
        if !p.is_empty() {
            let body = if p.len()>1 && p.last()==Some(&0x1b) && (p.starts_with(b"\\x1b]") || p.starts_with(b"\\x1bP")) {&p[..p.len()-1]} else {p.as_slice()};
            let sixel = if body.starts_with(b"\\x1bP") {
                let header = &body[2..];
                let final_index = header.iter().position(|b| !(0x30..=0x3f).contains(b));
                final_index.map_or(true, |i| header[i] == b'q' && header[i+1..].iter().all(|b| (0x20..=0x7e).contains(b)))
            } else { false };
            let permitted = body[0] >= 0xc2 || body == b"\\x1b" || body.starts_with(b"\\x1b[") || body.starts_with(b"\\x1b]") || sixel;
            anyhow::ensure!(permitted && body.iter().skip(1).all(|b|*b >= 0x20),
                "unsupported partial parser token or interleaved control");
        }
        let value = serde_json::json!({"version":2,"sequence":sequence,
            "state":self.state.prototype_checkpoint_state()?,"pending":p});
        let bytes = serde_json::to_vec(&value)?;
        anyhow::ensure!(bytes.len() <= 1048576, "checkpoint byte limit: {} > 1048576", bytes.len());
        Ok(bytes)
    }
}
''')
    with (scratch / "term/Cargo.toml").open("a") as f:
        # This declaration is a separate table: the upstream file ends in dependencies.termwiz.
        f.write('\n[dependencies.serde_json]\nversion = "1"\n')
    shutil.copyfile(HERE / "checkpoint-state.rs", scratch / "term/src/terminalstate/prototype-checkpoint.rs")
    shutil.copyfile(HERE / "checkpoint-graphics.rs", scratch / "term/src/terminalstate/prototype-graphics.rs")
    with (scratch / "term/src/terminalstate/mod.rs").open("a") as f:
        f.write('\ninclude!("prototype-checkpoint.rs");\n')
    with (scratch / "term/src/terminalstate/kitty.rs").open("a") as f:
        f.write('''\nimpl KittyImageState {
            pub(super) fn prototype_is_empty(&self) -> bool {
                self.accumulator.is_empty() && self.id_to_data.is_empty() && self.placements.is_empty()
                    && self.number_to_id.is_empty() && self.max_image_id == 0
            }
        }\n''')
        f.write('\ninclude!("prototype-kitty.rs");\n')
    shutil.copyfile(HERE / "checkpoint-kitty.rs", scratch / "term/src/terminalstate/prototype-kitty.rs")
    probe = out / "probe"
    probe.mkdir()
    (probe / "Cargo.toml").write_text((HERE / "Cargo.toml.in").read_text()
        .replace("@WEZTERM_SOURCE@", str(scratch)).replace("@PROTOTYPE_SOURCE@", str(probe))
        .replace("[dependencies]","[dependencies]\nlibc = \"0.2\""))
    shutil.copyfile(HERE / "Cargo.lock", probe / "Cargo.lock")
    text = (HERE / "main.rs").read_text().replace("let mut checkpoint_requests = 0;", "let mut checkpoint_requests = 0; let mut checkpoints = Vec::new();")
    text = text.replace("if event.checkpoint == Some(true) { checkpoint_requests += 1; }", """
            if event.checkpoint == Some(true) {
                checkpoint_requests += 1;
                checkpoints.push(match term.prototype_checkpoint(snapshots.len()) {
                    Ok(bytes) => json!({"event":snapshots.len(),"bytes":bytes,"size":bytes.len()}),
                    Err(error) => json!({"event":snapshots.len(),"error":format!("{error:#}")})
                });
            }
""")
    text = text.replace("let startup_us = start.elapsed().as_micros();", 'term.advance_bytes(b"\\x1b]2;\\x07"); let startup_us = start.elapsed().as_micros();')
    text = text.replace('"checkpoint":"NOT IMPLEMENTED: Rust-to-SwiftTerm transfer remains unproven"', '"checkpoints":checkpoints')
    text = text.replace("if let Err(error) = run()", 'if let Err(error) = if std::env::args().any(|a|a == "--live-pty") {live_pty_run()} else if std::env::args().any(|a|a == "--stream") {stream_run()} else {run()}')
    text += (HERE / "checkpoint-stream.rs").read_text()
    text += (HERE / "checkpoint-pty.rs").read_text()
    (probe / "main.rs").write_text(text)
    swift = out / "SwiftTerm"
    run(["cp", "-cR", str(ROOT / "Vendor/SwiftTerm"), str(swift)], out / "swift-copy.log")
    run(["patch", "--batch", "--forward", "-p1", "-d", str(swift), "-i",
         str(HERE / "swift-dcs-finalization.patch")], out / "swift-compatibility.log")
    from checkpoint_compatibility import extend_swift
    extend_swift(swift, replace_once)
    shutil.copyfile(HERE / "CheckpointBridge.swift", swift / "Sources/SwiftTerm/CheckpointBridge.swift")
    shutil.copyfile(HERE / "CheckpointGraphics.swift", swift / "Sources/SwiftTerm/CheckpointGraphics.swift")
    driver = out / "swift-probe"
    (driver / "Sources/Baseline").mkdir(parents=True)
    (driver / "Package.swift").write_text((ROOT / "script/native-comparison/swift/Package.swift").read_text()
        .replace("../../../Vendor/SwiftTerm", str(swift)))
    prefix = (ROOT / "script/native-comparison/swift/Sources/Baseline/main.swift").read_text().split("@MainActor\nfunc run() throws")[0]
    prefix = prefix.replace("var replies: [UInt8] = []", "var replies: [UInt8] = []; var suppressed = true; var suppressedBytes = 0")
    prefix = prefix.replace("replies.append(contentsOf: data)", "if suppressed { suppressedBytes += data.count } else { replies.append(contentsOf: data) }")
    prefix = prefix.replace("view.getTerminal().resize(cols: 20, rows: 6)", "view.getTerminal().resize(cols: 20, rows: 6)\n    view.getTerminal().changeScrollback(40)")
    (driver / "Sources/Baseline/main.swift").write_text(prefix + (HERE / "checkpoint-driver.swift").read_text())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path, help="Unmodified pinned source from run.py")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resume-build", action="store_true", help="Resume an interrupted scratch build, never reuse captured results")
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native macOS only")
    out = args.output.resolve()
    if not args.resume_build:
        if out.exists():
            parser.error("choose a fresh output directory")
        prepare(args.source.resolve(), out)
    elif (out / "results.json").exists():
        parser.error("results already captured; choose a fresh output directory")
    env = dict(os.environ, CARGO_TARGET_DIR=str(args.source.resolve().parent / "probe/target"))
    # serde_json is already pinned in the probe lock; the scratch core gains a dependency edge.
    run(["cargo", "+1.99.1", "build", "--offline", "--manifest-path", str(out / "probe/Cargo.toml")], out / "build.log", env=env)
    tests = run(["cargo", "+1.99.1", "test", "--locked", "--offline", "--manifest-path", str(out / "probe/Cargo.toml")], out / "test.log", env=env)
    (out / "rust-tests.txt").write_bytes(tests)
    run(["swift", "build", "--package-path", str(out / "swift-probe"), "--scratch-path", str(out / "swift-build")], out / "swift-build.log")
    from checkpoint_checks import check
    executable = out / "wezterm-checkpoint"
    shutil.copyfile(Path(env["CARGO_TARGET_DIR"]) / "debug/wezterm-feasibility", executable)
    executable.chmod(0o755)
    result = check(out, executable)
    (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    metadata = {"timestampUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "os":platform.platform(),
        "wezterm":WEZTERM,"finl":FINL,"scope":"scratch checkpoint bridge; tested subset only; not release acceptance",
        "sources":{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in
            [HERE / n for n in ["checkpoint.py","checkpoint-state.rs","CheckpointBridge.swift","checkpoint-driver.swift","checkpoint_checks.py","checkpoint-stream.rs",
                "main.rs","wezterm-compatibility.patch","swift-dcs-finalization.patch","Cargo.toml.in","Cargo.lock","checkpoint_report.py","checkpoint_compatibility.py","checkpoint-graphics.rs","CheckpointGraphics.swift","checkpoint-kitty.rs","checkpoint-pty.rs","checkpoint_pty_checks.py"]]},
        "baselineDriverSha256":hashlib.sha256((ROOT / "script/native-comparison/swift/Sources/Baseline/main.swift").read_bytes()).hexdigest()}
    metadata["probeLockSha256"] = hashlib.sha256((out / "probe/Cargo.lock").read_bytes()).hexdigest()
    (out / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(result["summary"]))
    if result["summary"]["failed"] or result["summary"]["unsupported"] or not result["summary"]["nativeStreamPassed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
