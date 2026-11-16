"""Evaluate measured targets without converting incomplete runs into passes."""
import argparse
import json
from pathlib import Path


def p95(values):
    return sorted(values)[min(len(values) - 1, int(len(values) * .95))] if values else None


def summarize(directory):
    path = Path(directory)
    result = json.loads((path / "results.json").read_text())
    run = json.loads((path / "run.json").read_text())
    regression = result["regression"]
    summary = {"completed": result.get("completed") is True, "run": str(path),
               "cycles": regression["cycles"], "regressionChecks": regression["checks"],
               "controlTimingScope": "idle two-request competition round trip; excludes cached visible rendering",
               "latency": {key: {"samples": len(regression[key]), "p95": p95(regression[key])}
                           for key in ("takeoverMs", "switchSyncMs", "replacementSyncMs")},
               "unmeasured": ["visible cached display latency", "production security integration", "multi-Mac network", "mobile clients"]}
    if "load" not in result:
        return summary
    load = result["load"]
    samples = load["samples"]
    if len(samples) < 2:
        raise RuntimeError("insufficient resource samples")
    span = samples[-1]["at"] - samples[0]["at"]
    rates = {}
    for server in ("a", "b"):
        for sid in (0, 1):
            before, after = [sample[server]["sessions"][sid]["bytes"] for sample in (samples[0], samples[-1])]
            achieved = (after - before) / span
            rates[f"{server}:{sid}"] = {"bytesPerSecond": achieved, "requestedRatio": achieved / load["rate"]}
    resource = {}
    first = {p["pid"]: p for p in samples[0]["processes"]}
    last = {p["pid"]: p for p in samples[-1]["processes"]}
    warm = next((sample for sample in samples if sample["at"] >= 30), None)
    for pid, initial in first.items():
        if pid not in last:
            raise RuntimeError("measured process disappeared")
        item = {"averageCpuPercent": (last[pid]["cpuTimeSeconds"] - initial["cpuTimeSeconds"]) / span * 100,
                "finalRssMiB": last[pid]["rssKiB"] / 1024}
        if warm and span >= 60:
            baseline = next(p["rssKiB"] for p in warm["processes"] if p["pid"] == pid)
            peak = max(p["rssKiB"] for sample in samples if sample["at"] >= warm["at"] for p in sample["processes"] if p["pid"] == pid)
            item["growthAfterWarmupMiB"] = (peak - baseline) / 1024
            item["within32MiB"] = item["growthAfterWarmupMiB"] <= 32
        resource[str(pid)] = item
    summary["load"] = {"seconds": load["seconds"], "policy": load["policy"], "requestedRate": load["rate"],
        "measuredRates": rates, "rateWithinFivePercent": all(.95 <= v["requestedRatio"] <= 1.05 for v in rates.values()),
        "resources": resource, "queueHighWaterBytes": max(s[server]["queueHighWater"] for s in samples for server in ("a", "b")),
        "configuredQueueBytes": run["arguments"]["queue"],
        "resyncs": {server: samples[-1][server]["resyncs"] - samples[0][server]["resyncs"] for server in ("a", "b")},
        "wireBytes": sum(samples[-1][s]["wireBytes"] - samples[0][s]["wireBytes"] for s in ("a", "b")),
        "echoP95Ms": p95([value["ms"] for value in load["echoMs"]]), "echoSamples": len(load["echoMs"]),
        "finalNativeParityAsserted": result.get("completed") is True and load.get("finalNativeParityAsserted") is True}
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    value = summarize(args.directory)
    (args.directory / "summary.json").write_text(json.dumps(value, indent=2) + "\n")
    print(json.dumps(value, indent=2))
