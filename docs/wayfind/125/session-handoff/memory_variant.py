"""Build a one-variable diagnostic from the exact native client used by a baseline."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--mode", choices=["autorelease", "bounded-copy"], default="autorelease")
    args = parser.parse_args()
    baseline = args.baseline.resolve()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    metadata = json.loads((baseline / "build.json").read_text())
    for name in ("server", "client"):
        actual = hashlib.sha256((baseline / name).read_bytes()).hexdigest()
        if actual != metadata["binaries"][name]:
            raise RuntimeError(f"baseline {name} binary changed")
    subprocess.run(["cp", "-cR", str(baseline / "native/swift-probe"), str(out / "swift-probe")], check=True)
    subprocess.run(["cp", "-cR", str(baseline / "native/swift-build"), str(out / "swift-build")], check=True)
    main_file = out / "swift-probe/Sources/Baseline/main.swift"
    before = main_file.read_text()
    if args.mode == "autorelease":
        start = 'DispatchQueue.main.async {\n                self.reading = false'
        finish = '} catch { self.fatal(error) }\n            }\n        }\n    }'
        stdin = 'DispatchQueue.main.async { driver.handle(line) }'
        if before.count(start) != 1 or before.count(finish) != 1 or before.count(stdin) != 1:
            raise RuntimeError("baseline source shape changed; refusing an ambiguous diagnostic patch")
        after = before.replace(start, 'DispatchQueue.main.async {\n                autoreleasepool {\n                self.reading = false')
        after = after.replace(finish, '} catch { self.fatal(error) }\n                }\n            }\n        }\n    }')
        after = after.replace(stdin, 'DispatchQueue.main.async { autoreleasepool { driver.handle(line) } }')
    else:
        after = before
        for name in ("observed", "echoTail"):
            old = f"pane.{name}.removeFirst(pane.{name}.count - 16384)"
            if after.count(old) != 1:
                raise RuntimeError("baseline diagnostic ring shape changed")
            after = after.replace(old, f"pane.{name} = Data(Array(pane.{name}.suffix(16384)))")
    main_file.write_text(after)
    (out / "variant.patch").write_text(''.join(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                                                fromfile="baseline/main.swift", tofile="pooled/main.swift")))
    with (out / "swift-build.log").open("w") as log:
        subprocess.run(["swift", "build", "--package-path", str(out / "swift-probe"), "-c", "release",
                        "--scratch-path", str(out / "swift-build")], stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copyfile(out / "swift-build/release/Baseline", out / "client")
    shutil.copyfile(baseline / "server", out / "server")
    for name in ("server", "client"):
        (out / name).chmod(0o755)
    (out / "build.json").write_text(json.dumps({"profile": "release", "diagnostic": args.mode,
        "baselineBuild": metadata, "baselineCombinedSourceSha256": hashlib.sha256(before.encode()).hexdigest(),
        "variantCombinedSourceSha256": hashlib.sha256(after.encode()).hexdigest(),
        "binaries": {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in ("server", "client")}}, indent=2) + "\n")
    print(out)


if __name__ == "__main__":
    main()
