"""Run the matched isolation, queue comparison and long stress checks serially."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--isolation-only", action="store_true")
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    cases = [
        ("normal-fast", ["--seconds", "60", "--rate", "102400", "--policy", "continuous"]),
        ("normal-slow", ["--seconds", "120", "--rate", "102400", "--policy", "continuous", "--slow-seconds", "30"]),
        ("queue-4m", ["--seconds", "45", "--rate", "1048576", "--policy", "continuous", "--slow-seconds", "30", "--queue", "4194304"]),
        ("stress", ["--seconds", "1800", "--rate", "1048576", "--policy", "visible", "--slow-seconds", "30", "--during-load-cycles", "100"]),
    ]
    if args.isolation_only:
        cases = cases[:2]
    completed = []
    for name, flags in cases:
        print(json.dumps({"starting": name}), flush=True)
        command = [sys.executable, str(HERE / "run.py"), "--build", str(args.build.resolve()),
                   "--output", str(out / name), "--cycles", "0", *flags]
        with (out / f"{name}.log").open("w") as log:
            code = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT).returncode
        case = {"name": name, "exitCode": code, "command": command}
        if code == 0:
            from analyze import summarize
            case["summary"] = summarize(out / name)
        completed.append(case)
        (out / "cases.json").write_text(json.dumps(completed, indent=2) + "\n")
        print(json.dumps({"finished": name, "exitCode": code}), flush=True)
        if code != 0:
            sys.exit(code)


if __name__ == "__main__":
    main()
