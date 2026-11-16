"""Run serial five-minute normal-rate baselines without shared-environment changes."""
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
    parser.add_argument("--seconds", type=int, default=300)
    parser.add_argument("--rates", type=int, nargs="+", default=[10240, 102400])
    parser.add_argument("--queue", type=int, default=1048576)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    cases = []
    for policy in ["visible", "continuous"]:
        for rate in args.rates:
            destination = out / f"{policy}-{rate}"
            command = [sys.executable, str(HERE / "run.py"), "--build", str(args.build.resolve()),
                       "--output", str(destination), "--cycles", "0", "--seconds", str(args.seconds),
                       "--rate", str(rate), "--policy", policy, "--queue", str(args.queue)]
            print(json.dumps({"starting": destination.name}), flush=True)
            with (out / f"{destination.name}.log").open("w") as log:
                process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            case = {"policy": policy, "rate": rate, "exitCode": process.returncode, "directory": str(destination)}
            if process.returncode == 0:
                from analyze import summarize
                case["summary"] = summarize(destination)
            cases.append(case)
            (out / "cases.json").write_text(json.dumps(cases, indent=2) + "\n")
            print(json.dumps({"finished": destination.name, "exitCode": process.returncode}), flush=True)
    if any(case["exitCode"] for case in cases):
        sys.exit(1)


if __name__ == "__main__":
    main()
