"""Verify or refresh the visual's embedded timeline from retained native evidence."""
import argparse
import gzip
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    with gzip.open(HERE / "evidence/myterm-166-release-smoke-13/samples.jsonl.gz", "rt") as source:
        samples = [json.loads(line) for line in source]
    if max(sample["a"]["resyncs"] for sample in samples) != 22:
        raise RuntimeError("timeline captions require review for the selected evidence")
    with gzip.open(HERE / "evidence/myterm-166-release-smoke-13/results.json.gz", "rt") as source:
        short = json.load(source)["load"]
    run = json.loads((HERE / "evidence/myterm-166-release-smoke-13/run.json").read_text())
    long = json.loads((HERE / "evidence/myterm-166-followups-19-stress/summary.json").read_text())["load"]
    points = [[round(sample["at"], 3), sample["a"]["resyncs"]] for sample in samples]
    path = HERE / "recovery-evidence.html"
    html = path.read_text()
    percentile = lambda values: sorted(values)[min(len(values)-1, int(len(values)*.95))]
    tokens = [format(max(s[server]["queueHighWater"] for s in samples for server in ("a", "b")), ","),
              format(run["arguments"]["queue"], ","), f"{percentile([s['ms'] for s in short['echoMs']]):.2f}",
              str(len(short["echoMs"])), f"{max(p['growthAfterWarmupMiB'] for p in long['resources'].values()):.2f}",
              f"{long['loadedControlTiming']['takeoverRoundTripP95Ms']:.2f}",
              f"{long['loadedControlTiming']['replacementSyncP95Ms']:.2f}"]
    if any(token not in html for token in tokens):
        raise RuntimeError("a displayed measurement differs from retained evidence")
    start = html.index("const samples=") + len("const samples=")
    end = html.index(";\nconst x=", start)
    embedded = json.loads(html[start:end])
    if args.write:
        path.write_text(html[:start] + json.dumps(points, separators=(",", ":")) + html[end:])
    elif embedded != points:
        raise RuntimeError("embedded timeline differs from retained native evidence")
    print(f"Verified {len(points)} native timeline samples")


if __name__ == "__main__":
    main()
