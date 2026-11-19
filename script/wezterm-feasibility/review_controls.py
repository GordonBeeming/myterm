"""Bounded controls added after independent review; these do not prove reconnect."""
import json

from run import run


def check_review_controls(original_exe, patched_exe, out, env):
    traces = []
    for width in (6, 10, 20):
        for count in (0, 19, 20, 21, 39, 40, 41):
            traces.append({"name": f"wrap-{count}-via-{width}", "events": [
                {"data": list(b"A" * count)}, {"resize": [width, 6]},
                {"resize": [20, 6]}, {"data": list(b"X")}]})
    traces.append({"name": "sixel-8452", "events": [{"data": list(
        b'\x1b[2;3H\x1b[?8452h\x1bPq"1;1;9;6#1;2;100;0;0#1!9~\x1b\\X')}]})
    payload = json.dumps(traces).encode()
    (out / "review-fixtures.json").write_bytes(payload)
    results = {}
    for name, executable in [("original", original_exe), ("patched", patched_exe)]:
        captured = run([str(executable)], out / (name + "-review.log"), data=payload, env=env)
        (out / (name + "-review-traces.json")).write_bytes(captured)
        results[name] = json.loads(captured)
    verdicts = {}
    fields = ["cells", "styles", "cursor", "alt", "history", "replies", "modes"]
    for trace in traces:
        name = trace["name"]
        before = results["original"][name]["snapshots"][-1]
        after = results["patched"][name]["snapshots"][-1]
        differences = [field for field in fields if before[field] != after[field]]
        if differences:
            raise RuntimeError(f"review control {name} regressed after its output suffix: {differences}")
        verdicts[name] = {"passed": True, "originalCursor": before["cursor"], "patchedCursor": after["cursor"]}
    if results["patched"]["sixel-8452"]["snapshots"][-1]["imageCells"] <= 0:
        raise RuntimeError("Sixel 8452 control lost its image")
    hidden = [{"name": "hidden-column-retention", "events": [
        {"data": list(b"\x1b[?1049h")}, {"resize": [1000, 6]}, {"data": list(b"A" * 999)},
        {"resize": [6, 6]}, {"resize": [20, 6]}, {"resize": [1000, 6]},
        {"resize": [6, 6]}, {"resize": [20, 6]}]}]
    captured = run([str(patched_exe)], out / "hidden-column.log", data=json.dumps(hidden).encode(), env=env)
    (out / "hidden-column-traces.json").write_bytes(captured)
    snapshots = json.loads(captured)["hidden-column-retention"]["snapshots"]
    for snapshot in snapshots[2:]:
        visible = sum(cell.count("A") for row in snapshot["cells"] for cell in row)
        hidden_count = sum(cell["text"].count("A") for cell in snapshot["hiddenCells"])
        if visible + hidden_count != 999:
            raise RuntimeError("resize lost or duplicated retained column content")
    if not snapshots[3]["hiddenCells"] or snapshots[5]["hiddenCells"]:
        raise RuntimeError("hidden columns were not exposed/hidden with the viewport")
    verdicts["hidden-column-retention"] = {"passed": True,
        "maximumTestedColumns": 1000, "maximumStoredColumns": max(max(s["storedRowWidths"]) for s in snapshots),
        "scope": "999 text cells survive this resize sequence; historical width persists; no production retention bound established"}
    (out / "review-control-results.json").write_text(json.dumps(verdicts, indent=2) + "\n")
    return len(verdicts)
