"""Apply experimental compatibility patches only to scratch copies, then verify them."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil

from run import ROOT, WEZTERM, FINL, compare, run
from review_controls import check_review_controls


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-results", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin":
        parser.error("native macOS only")
    baseline, out = args.baseline_results.resolve(), args.output.resolve()
    prototype = Path(__file__).resolve().parent
    metadata = json.loads((baseline / "run.json").read_text())
    fixtures = ROOT / "script/native-comparison/fixtures.json"
    swift_source = ROOT / "script/native-comparison/swift/Sources/Baseline/main.swift"
    if (metadata["wezterm"], metadata["finl"]) != (WEZTERM, FINL):
        raise RuntimeError("baseline revisions do not match this prototype")
    if metadata["fixtureSha256"] != digest(fixtures) or metadata["baselineSourceSha256"] != digest(swift_source):
        raise RuntimeError("baseline fixtures or Swift driver changed; regenerate baseline first")
    if metadata.get("probeSourceSha256") != digest(prototype / "main.rs") or not metadata.get("replyCapture"):
        raise RuntimeError("baseline probe or reply-drain capture is stale; regenerate baseline first")
    if out.exists():
        raise RuntimeError("choose a fresh output directory")
    out.mkdir(parents=True)
    for name in ["source", "finl"]:
        run(["cp", "-cR", str(baseline / name), str(out / name)], out / (name + "-copy.log"))
    manifest = out / "source/Cargo.toml"
    original = manifest.read_text()
    rewritten = original.replace(str(baseline / "finl"), str(out / "finl"))
    if rewritten == original:
        raise RuntimeError("cannot relocate finl dependency")
    manifest.write_text(rewritten)
    patch = prototype / "wezterm-compatibility.patch"
    run(["patch", "--batch", "--forward", "-p1", "-d", str(out / "source"), "-i", str(patch)], out / "rust-patch.log")
    probe = out / "probe"
    probe.mkdir()
    (probe / "Cargo.toml").write_text((prototype / "Cargo.toml.in").read_text()
        .replace("@WEZTERM_SOURCE@", str(out / "source")).replace("@PROTOTYPE_SOURCE@", str(prototype)))
    shutil.copyfile(prototype / "Cargo.lock", probe / "Cargo.lock")
    run(["cargo", "+1.99.1", "build", "--locked", "--manifest-path", str(probe / "Cargo.toml")], out / "build.log")
    tests = run(["cargo", "+1.99.1", "test", "--locked", "--manifest-path", str(probe / "Cargo.toml")], out / "test.log")
    (out / "test-stdout.log").write_bytes(tests)
    width, height = metadata["cellPixels"]
    env = dict(os.environ, CELL_WIDTH=str(width), CELL_HEIGHT=str(height))
    payload = fixtures.read_bytes()
    candidate = run(["/usr/bin/time", "-l", str(probe / "target/debug/wezterm-feasibility")],
                    out / "probe-time.log", data=payload, env=env)
    (out / "wezterm-traces.json").write_bytes(candidate)
    rust = json.loads(candidate)
    swift = json.loads((baseline / "swift-traces.json").read_text())
    original_comparison = compare(swift, rust)
    save_json(out / "original-baseline-comparison.json", original_comparison)
    # Retain the original baseline as a separate reference. Never hide its split-DCS failure.
    shutil.copyfile(baseline / "swift-traces.json", out / "swift-original-traces.json")
    swift_copy = out / "SwiftTerm"
    run(["cp", "-cR", str(ROOT / "Vendor/SwiftTerm"), str(swift_copy)], out / "swift-copy.log")
    swift_patch = prototype / "swift-dcs-finalization.patch"
    run(["patch", "--batch", "--forward", "-p1", "-d", str(swift_copy), "-i", str(swift_patch)], out / "swift-patch.log")
    swift_probe = out / "swift-probe"
    (swift_probe / "Sources/Baseline").mkdir(parents=True)
    swift_manifest = (ROOT / "script/native-comparison/swift/Package.swift").read_text()
    (swift_probe / "Package.swift").write_text(swift_manifest.replace("../../../Vendor/SwiftTerm", str(swift_copy)))
    shutil.copyfile(swift_source, swift_probe / "Sources/Baseline/main.swift")
    run(["swift", "build", "--package-path", str(swift_probe), "--scratch-path", str(out / "swift-build")], out / "swift-build.log")
    swift_exe = out / "swift-build/debug/Baseline"
    corrected = run([str(swift_exe)], out / "swift-stderr.log", data=payload)
    (out / "swift-traces.json").write_bytes(corrected)
    corrected_swift = json.loads(corrected)
    measured_geometry = {tuple(s["cellPixels"]) for t in corrected_swift.values() for s in t["snapshots"]}
    if measured_geometry != {(width, height)}:
        raise RuntimeError("SwiftTerm geometry changed; regenerate baseline first")
    comparison = compare(corrected_swift, rust)
    save_json(out / "comparison.json", comparison)
    controls = (prototype / "compatibility-fixtures.json").read_bytes()
    swift_controls = run([str(swift_exe)], out / "swift-controls.log", data=controls)
    rust_controls = run([str(probe / "target/debug/wezterm-feasibility")], out / "rust-controls.log", data=controls, env=env)
    (out / "swift-controls.json").write_bytes(swift_controls)
    (out / "rust-controls.json").write_bytes(rust_controls)
    protocol_fixture = [t for t in json.loads(controls) if t["name"] == "kitty-two-rows"]
    original_protocol = run([str(baseline / "probe/target/debug/wezterm-feasibility")],
                            out / "protocol-original.log", data=json.dumps(protocol_fixture).encode(), env=env)
    save_json(out / "protocol-probe.json", {
        "origin": [2, 1], "placement": [2, 2],
        "originalRust": json.loads(original_protocol)["kitty-two-rows"]["snapshots"][-1]["cursor"],
        "patchedRust": json.loads(rust_controls)["kitty-two-rows"]["snapshots"][-1]["cursor"],
        "nativeSwift": json.loads(swift_controls)["kitty-two-rows"]["snapshots"][-1]["cursor"],
        "reviewerInterpretation": [4, 2], "protocolExpected": [4, 3],
        "source": "https://sw.kovidgoyal.net/kitty/graphics-protocol/#controlling-displayed-image-layout"})
    control_comparison = compare(json.loads(swift_controls), json.loads(rust_controls))
    save_json(out / "control-comparison.json", control_comparison)
    review_controls = check_review_controls(baseline / "probe/target/debug/wezterm-feasibility",
                                            probe / "target/debug/wezterm-feasibility", out, env)
    # Within each engine, the complete split Sixel must retain images and the
    # same measured state as the unsplit positive control before its suffix.
    for name, traces, image_field in [("SwiftTerm", corrected_swift, "imageStripes"), ("wezterm", rust, "imageCells")]:
        whole = traces["sixel-full-positive-control"]["snapshots"][0]
        split = traces["sixel-full-split"]["snapshots"][-1]
        if whole[image_field] <= 0 or split[image_field] != whole[image_field]:
            raise RuntimeError(f"{name}: split Sixel lost its graphics positive control")
        for field in ["cells", "styles", "cursor", "alt", "history", "replies"]:
            if whole[field] != split[field]:
                raise RuntimeError(f"{name}: split and unsplit Sixel differ in {field}")
    metadata.update({"timestampUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                     "scope": "patched scratch copies; measured projection only; reconnect is unproven",
                     "rustPatchSha256": digest(patch), "swiftPatchSha256": digest(swift_patch),
                     "controlFixtureSha256": digest(prototype / "compatibility-fixtures.json"),
                     "probeSourceSha256": digest(prototype / "main.rs"),
                     "baselineReference": str(baseline),
                     "originalMatches": sum(t["projectionMatches"] for t in original_comparison.values()),
                     "correctedMatches": sum(t["projectionMatches"] for t in comparison.values()),
                     "controlMatches": sum(t["projectionMatches"] for t in control_comparison.values())})
    metadata["reviewControlPasses"] = review_controls
    metadata["reviewControlSourceSha256"] = digest(prototype / "review_controls.py")
    save_json(out / "run.json", metadata)
    if any(not t["projectionMatches"] for t in comparison.values()) or any(not t["projectionMatches"] for t in control_comparison.values()):
        raise RuntimeError("compatibility gate failed; inspect retained comparisons")
    print(f"PASS: {metadata['correctedMatches']}/17 corrected projections; {metadata['controlMatches']}/9 controls; {review_controls} review controls; split graphics retained")


if __name__ == "__main__":
    main()
