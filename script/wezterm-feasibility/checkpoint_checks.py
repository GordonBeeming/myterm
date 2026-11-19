"""Independent fresh-client continuation checks, including failure controls."""
import base64
import copy
import hashlib
import io
import json
import os
import plistlib
import struct
import subprocess
import threading
from pathlib import Path
from PIL import Image

from run import ROOT, run


def semantic(encoded):
    state = plistlib.loads(base64.b64decode(encoded))["state"]
    graphemes = {g["index"]:g["character"] for g in state["graphemes"]}

    def color(c):
        # Native default foreground/background variants both mean default here.
        if c[0] not in (0, 1, 2, 3):
            raise ValueError("unexpected native color kind")
        return (2, 0, 0, 0) if c[0] in (2, 3) else tuple(c)

    def attribute(a):
        def c(value):
            return color([value[k] for k in ["kind","first","second","third"]])
        underline = a.get("underlineColor")
        return [c(a["foreground"]),c(a["background"]),a["style"],a["underlineStyle"],
            c(underline) if underline and underline["kind"] not in (2,3) else None]

    def buffer(b):
        lines = []
        for line in b["lines"]:
            data = line["cellData"]
            cells = []
            for offset in range(0, len(data), 23):
                code = struct.unpack_from("<i", data, offset)[0]
                text = graphemes.get(code, chr(code) if 0 <= code <= 0x10ffff else "UNKNOWN")
                text = "" if text in ("\0", " ") else text
                link = struct.unpack_from("<i", data, offset + 19)[0]
                cells.append([text, data[offset+4] if text else 0, color(data[offset+5:offset+9]),
                    color(data[offset+9:offset+13]), data[offset+13],
                    line["hyperlinks"][link] if link >= 0 else None])
            while len(cells) > state["columns"] and cells[-1] == ["", 0, (2, 0, 0, 0), (2, 0, 0, 0), 0, None]:
                cells.pop()
            images = []
            for image in line["images"]:
                with Image.open(io.BytesIO(image["data"])) as decoded:
                    rgba = decoded.convert("RGBA")
                    pixels = hashlib.sha256(rgba.tobytes()).hexdigest()
                images.append({k:v for k,v in image.items() if k != "data"} | {"rgbaSha256":pixels})
            lines.append({"cells":cells,"wrapped":line["isWrapped"],"images":images})
        if not lines:
            blank = ["", 0, (2, 0, 0, 0), (2, 0, 0, 0), 0, None]
            lines = [{"cells":[blank] * state["columns"],"wrapped":False,"images":[]} for _ in range(state["rows"])]
        return {"lines":lines,"x":b["x"],"y":b["y"],"history":b["yBase"],
            "margins":[b[k] for k in ["scrollTop","scrollBottom","marginLeft","marginRight"]],
            "tabs":b["tabStops"][:state["columns"]],"yDisplay":b["yDisplay"],
            "savedCursor":[b[k] for k in ["savedX","savedY","savedOriginMode","savedMarginMode",
                "savedWraparound","savedReverseWraparound"]],"savedAttribute":attribute(b["savedAttribute"])}

    result = {key:state[key] for key in ["columns","rows","alternateActive","applicationCursor",
        "applicationKeypad","originMode","marginMode","insertMode","wraparound","reverseWraparound",
        "bracketedPasteMode","sendFocus","cursorHidden","mouseMode","mouseProtocol","lineFeedMode",
        "terminalTitle","iconTitle","keyboardNormal","keyboardAlternate"]}
    result["normal"] = buffer(state["normalBuffer"])
    result["alternate"] = buffer(state["alternateBuffer"])
    result["pen"] = attribute(state["currentAttribute"])
    result["tabWidth"] = state["tabStopWidth"]
    result["directory"] = state.get("hostCurrentDirectory")
    result["cursorStyle"] = state["options"]["cursorStyle"]
    kitty = state["kitty"]
    cache = []
    for image in kitty["images"]:
        if image["kind"]==1:
            pixels = image["data"]; dimensions = [image["width"],image["height"]]
        else:
            with Image.open(io.BytesIO(image["data"])) as decoded:
                rgba = decoded.convert("RGBA"); pixels = rgba.tobytes(); dimensions = list(rgba.size)
        cache.append([image["id"],dimensions,hashlib.sha256(pixels).hexdigest()])
    result["kitty"] = {"cache":cache,"numbers":kitty["imageNumbers"],"placements":kitty["placements"],
        "nextImageId":kitty["nextImageId"],"nextPlacementId":kitty["nextPlacementId"],"pending":kitty.get("pending")}
    return result


def check(out, rust):
    swift = out / "swift-build/debug/Baseline"
    fixtures = json.loads((ROOT / "script/native-comparison/fixtures.json").read_bytes())
    extra = [
        {"name":"wrap-pending", "events":[{"data":list(b"ABCDEFGHIJKLMNOPQRST"),"checkpoint":True},{"data":list(b"Z")}]},
        {"name":"saved-cursor", "events":[{"data":list(b"hello\x1b7\x1b[4;8Hother"),"checkpoint":True},{"data":list(b"\x1b8!")}]},
        {"name":"margins-tabs-insert", "events":[{"data":list(b"\x1b[2;5r\x1b[4h\x1b[3;3Habc"),"checkpoint":True},{"data":list(b"\r\tX\r\nY")}]},
        {"name":"combining-after-reconnect", "events":[{"data":list(b"e"),"checkpoint":True},{"data":list("\u0301!".encode())}]},
        {"name":"query-no-replay", "events":[{"data":list(b"\x1b[3;7H\x1b[6n\x1b[5n"),"checkpoint":True},{"data":list(b"\x1b[6n")}]},
        {"name":"long-session", "events":[{"data":list(b"unchanging\r\n"*10000),"checkpoint":True},{"data":list(b"tail\r\n")}]},
        {"name":"shorter-session", "events":[{"data":list(b"unchanging\r\n"*1000),"checkpoint":True},{"data":list(b"tail\r\n")}]},
        {"name":"token-overflow", "events":[{"data":list(b"\x1b]2;"+b"a"*20000),"checkpoint":True}]},
        {"name":"repeat-after-reconnect", "events":[{"data":list(b"A"),"checkpoint":True},{"data":list(b"\x1b[3b")}]},
        {"name":"saved-wrap-mode", "events":[{"data":list(b"hello\x1b7\x1b[?7l"),"checkpoint":True},{"data":list(b"\x1b8ABCDEFGHIJKLMNOPQRST!")}]},
        {"name":"cursor-style", "events":[{"data":list(b"\x1b[4 q"),"checkpoint":True},{"data":list(b"after")}]},
        {"name":"dense-80x24", "events":[{"resize":[80,24]},{"data":list(b"\x1b[1;4;31m"+(b"X"*80+b"\r\n")*64),"checkpoint":True},{"data":list(b"tail")}]},
        {"name":"dense-120x40", "events":[{"resize":[120,40]},{"data":list(b"\x1b[1;4;31m"+(b"X"*120+b"\r\n")*80),"checkpoint":True}]},
        {"name":"allocated-cell-limit", "events":[{"resize":[1000,100],"checkpoint":True}]},
    ]
    fixtures += extra
    fixtures += [
        {"name":"query-split-at-import", "events":[{"data":list(b"\x1b[3;7H\x1b[6"),"checkpoint":True},
            {"data":list(b"n\r\ncontinued")}]},
        {"name":"full-history-row-shrink", "events":[{"data":list(b"line\r\n"*100)},
            {"resize":[20,3],"checkpoint":True},{"data":list(b"tail\r\n")}]},
        {"name":"saved-column-shrink", "events":[{"data":list(b"\x1b[1;19H\x1b7")},
            {"resize":[10,6],"checkpoint":True},{"data":list(b"\x1b8!")}]},
        {"name":"kitty-pending-display", "events":[
            {"data":list(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,m=1;/wAA\x1b\\"),"checkpoint":True},
            {"data":list(b"\x1b_Gm=0;/w==\x1b\\after")}]},
    ]
    reset_images = bytearray()
    for i in range(70):
        encoded = io.BytesIO()
        Image.new("RGBA", (1,1), (i,255-i,0,255)).save(encoded,format="PNG")
        reset_images += b"\x1b]1337;File=inline=1;width=1;height=1:"+base64.b64encode(encoded.getvalue())+b"\x07"
    fixtures.append({"name":"image-metadata-scrolled-away","events":[{"resize":[20,100]},
        {"data":list(reset_images+b"\r\n"*300),"checkpoint":True},{"data":list(b"after-scroll")}]})
    fixtures.append({"name":"image-metadata-reset","events":[{"resize":[20,100]},{"data":list(reset_images+b"\x1bc"),"checkpoint":True},
        {"data":list(b"after-reset")}]})
    png = io.BytesIO()
    image = Image.new("RGBA",(2,2))
    image.putdata([(255,0,0,255),(0,255,0,255),(0,0,255,255),(255,255,255,255)])
    image.save(png,format="PNG")
    fixtures.append({"name":"iterm-valid-png","events":[{"data":list(b"\x1b]1337;File=inline=1;width=2;height=2:"+
        base64.b64encode(png.getvalue())+b"\x07"),"checkpoint":True},{"data":list(b"after-valid-image")} ]})
    kitty_whole = b"\x1b_Ga=t,f=32,s=1,v=1,i=1;/wAA/w==\x1b\\"
    kitty_place = b"\x1b_Ga=p,i=1,p=1,c=2,r=1;\x1b\\"
    fixtures += [
        {"name":"kitty-retained-image","events":[{"data":list(kitty_whole+kitty_place),"checkpoint":True},
            {"data":list(b"\r\n\x1b_Ga=p,i=1,p=2,c=1,r=1;\x1b\\")} ]},
        {"name":"kitty-cached-offscreen","events":[{"data":list(kitty_whole),"checkpoint":True},
            {"data":list(kitty_place)} ]},
        {"name":"keyboard-set-push-pop","events":[{"data":list(b"\x1b[=3u\x1b[>7u"),"checkpoint":True},
            {"data":list(b"\x1b[<u\x1b[?u\x1b[<9u\x1b[?u")} ]},
        {"name":"osc-st-split","events":[{"data":list(b"\x1b]2;partial-title\x1b"),"checkpoint":True},
            {"data":list(b"\\after-title")} ]},
        {"name":"kitty-delete-after-restore","events":[{"data":list(kitty_whole+kitty_place),"checkpoint":True},
            {"data":list(b"\x1b_Ga=d,d=I,i=1;\x1b\\")} ]},
        {"name":"alternate-keyboard-and-margins","events":[{"data":list(b"\x1b[2;5r\x1b[?1049h\x1b[>3u\x1b[3;6r"),"checkpoint":True},
            {"data":list(b"\x1b[?1049l\x1b[?u\x1b[?1049h\x1b[?u")} ]},
    ]
    fixtures += [
        {"name":"kitty-left-alternate", "events":[{"data":list(kitty_whole+b"\x1b[?1049h"+kitty_place+b"\x1b[?1049l"),"checkpoint":True},
            {"data":list(b"!")} ]},
        {"name":"kitty-reset", "events":[{"data":list(kitty_whole+kitty_place+b"\x1bc"),"checkpoint":True},
            {"data":list(b"!")} ]},
        {"name":"kitty-pending-explicit-placement", "events":[
            {"data":list(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,p=3,c=2,r=1,C=1,z=-1,m=1;/wAA\x1b\\"),"checkpoint":True},
            {"data":list(b"\x1b_Gm=0;/w==\x1b\\after")} ]},
        {"name":"kitty-replaced-placement-alternate", "events":[{"data":list(kitty_whole+kitty_place+b"\x1b[?1049h\x1b[3;5H"+kitty_place),"checkpoint":True},
            {"data":list(b"!\x1b_Ga=d,d=I,i=1;\x1b\\")} ]},
        {"name":"kitty-replaced-placement-normal", "events":[{"data":list(kitty_whole+b"\x1b[?1049h"+kitty_place+b"\x1b[?1049l\x1b[3;5H"+kitty_whole+kitty_place),"checkpoint":True},
            {"data":list(b"!\x1b_Ga=d,d=I,i=1;\x1b\\")} ]},
    ]
    env = dict(os.environ, CELL_WIDTH="9", CELL_HEIGHT="16")
    payload = json.dumps(fixtures).encode()
    (out / "fixtures.json").write_bytes(payload)
    candidate = json.loads(run([str(rust)], out / "rust-capture.log", data=payload, env=env))
    (out / "rust-traces.json").write_text(json.dumps(candidate))
    boundary_fixtures = [
        {"name":"automatic-placement-id","events":[{"data":list(kitty_whole+b"\x1b_Ga=p,i=1,c=2,r=1;\x1b\\"),"checkpoint":True}]},
        {"name":"pending-placement-offset","events":[{"data":list(b"\x1b_Ga=T,f=32,s=1,v=1,i=7,p=3,X=1,m=1;/wAA\x1b\\"),"checkpoint":True}]},
        {"name":"non-sixel-dcs","events":[{"data":list(b"\x1bP$qm"),"checkpoint":True}]},
    ]
    boundaries = json.loads(run([str(rust)],out/"boundary-capture.log",data=json.dumps(boundary_fixtures).encode(),env=env))
    expected_boundaries = {"automatic-placement-id":"unsupported automatic Kitty placement identity",
        "pending-placement-offset":"unsupported pending Kitty placement geometry",
        "non-sixel-dcs":"unsupported partial parser token"}
    boundary_controls = {}
    for name,diagnostic in expected_boundaries.items():
        checkpoint = boundaries[name]["checkpoints"][0]
        boundary_controls[name] = "bytes" not in checkpoint and diagnostic in checkpoint.get("error","")
    if not all(boundary_controls.values()):
        raise RuntimeError(f"exporter boundary control failed: {boundary_controls}")
    (out/"boundary-controls.json").write_text(json.dumps(boundaries))
    cases = []
    imports = []
    checkpoints = []
    for trace in fixtures:
        name = trace["name"]
        events = [{"sequence":i,"event":e} for i,e in enumerate(trace["events"])]
        reference = json.loads(run([str(swift)], out / f"{name}-reference.log",
            data=json.dumps({"events":events}).encode()))
        for checkpoint in candidate[name]["checkpoints"]:
            cut = checkpoint["event"]
            if "error" in checkpoint:
                expected_limits = {"token-overflow":"unfinished-token limit","allocated-cell-limit":"allocated cell limit"}
                expected = name in expected_limits and expected_limits[name] in checkpoint["error"]
                cases.append({"name":name,"event":cut,"status":"rejected-limit" if expected else "unsupported","reason":checkpoint["error"]})
                continue
            request = {"checkpoint":checkpoint["bytes"],"events":events[cut+1:]}
            result = subprocess.run([str(swift)], input=json.dumps(request).encode(), capture_output=True, timeout=30)
            if result.returncode:
                cases.append({"name":name,"event":cut,"status":"failed-import","reason":result.stderr.decode()[-3000:]})
                continue
            restored = json.loads(result.stdout)
            if name in ["sixel-full-positive-control","sixel-full-split","kitty-rgba-split","iterm-valid-png","kitty-retained-image"]:
                expected_images = semantic(reference["snapshots"][-1]["nativeCheckpoint"])
                actual_images = semantic(restored["snapshots"][-1]["nativeCheckpoint"])
                def count_images(state):
                    return sum(len(line["images"]) for buffer in ["normal","alternate"] for line in state[buffer]["lines"])
                if count_images(expected_images)==0 or count_images(actual_images)==0:
                    raise RuntimeError(f"native graphics positive control lost its images: {name}")
            imports.append(restored["importNs"])
            checkpoints.append(checkpoint["size"])
            reference_snapshots = reference["snapshots"][cut:]
            differences = []
            old_replies = reference_snapshots[0]["replies"]
            for offset, (expected, actual) in enumerate(zip(reference_snapshots, restored["snapshots"], strict=True)):
                fields = [f for f in ["cells","styles","cursor","alt","history"] if expected[f] != actual[f]]
                if actual["replies"] != expected["replies"][len(old_replies):]:
                    fields.append("replies")
                expected_state, actual_state = semantic(expected["nativeCheckpoint"]), semantic(actual["nativeCheckpoint"])
                fields += ["state."+k for k in expected_state if expected_state[k] != actual_state[k]]
                if fields:
                    differences.append({"offset":offset,"fields":fields})
            cases.append({"name":name,"event":cut,"status":"failed-continuation" if differences else "passed",
                "checkpointBytes":checkpoint["size"],"importNs":restored["importNs"],
                "differences":differences})
            (out / f"{name}-{cut}-clients.json").write_text(json.dumps({"reference":reference,"restored":restored}))

    # Exercise protocol failures with a real exported checkpoint and native receiver.
    sample = candidate["ascii-and-cursor"]["checkpoints"][0]
    if "bytes" not in sample:
        raise RuntimeError("ASCII positive checkpoint unavailable for receiver controls")
    envelope = json.loads(bytes(sample["bytes"]))
    seq = envelope["sequence"]
    controls = {}
    twin_passes = 0
    def rejected(request, expected, twin_request=None):
        nonlocal twin_passes
        twin_request = twin_request or {"checkpoint":sample["bytes"],"events":[]}
        twin = subprocess.run([str(swift)], input=json.dumps(twin_request).encode(),
            capture_output=True,timeout=10)
        if twin.returncode or not twin.stdout:
            raise RuntimeError("negative-control positive twin failed")
        twin_passes += 1
        result = subprocess.run([str(swift)], input=json.dumps(request).encode(),capture_output=True,timeout=10)
        return result.returncode == 1 and not result.stdout and expected in result.stderr.decode()
    for label, sequences in {"gap":[seq+2], "duplicate":[seq+1,seq+1], "reordered":[seq+2,seq+1]}.items():
        request = {"checkpoint":sample["bytes"],"events":[{"sequence":s,"event":{"data":[65]}} for s in sequences]}
        twin_request = {"checkpoint":sample["bytes"],"events":[
            {"sequence":seq+i+1,"event":{"data":[65]}} for i in range(len(sequences))]}
        controls[label] = rejected(request, "delivery sequence gap, duplicate or reordering", twin_request)
    mutations = {
        "non-sixel-dcs":lambda e:e.update(pending=list(b"\x1bP$qm")),
        "mismatched-image-geometry":lambda e:e["state"].update(cellPixels=[10,16]),
        "version":lambda e:e.update(version=99),
        "bad-dimensions":lambda e:e["state"].update(columns=0),
        "oversize-token":lambda e:e.update(pending=[65]*16385),
        "bad-cell-width":lambda e:e["state"]["normal"]["lines"][0]["cells"][0].update(width=3),
        "completed-query-as-token":lambda e:e.update(pending=list(b"\x1b[6n")),
        "oversize-checkpoint":lambda e:e.update(padding="x"*1048576),
        "overflow-cursor":lambda e:e["state"].update(cursor=[9223372036854775807,0],wrapNext=True),
        "overflow-cell":lambda e:e["state"]["normal"]["lines"][0]["cells"][0].update(x=9223372036854775807),
        "invalid-utf8-prefix":lambda e:e.update(pending=[0xf4,0x90]),
        "sequence-limit":lambda e:e.update(sequence=9223372036854775807),
        "short-tabs":lambda e:e["state"].update(tabs=[]),
        "bad-margins":lambda e:e["state"].update(margins=[-1,6,0,20]),
        "bad-mouse-mode":lambda e:e["state"]["modes"].update(mouse=99),
        "bad-repetitions":lambda e:e["state"]["normal"]["lines"][0]["cells"][0].update(repetitions=1001),
        "bad-last-storage":lambda e:e["state"].update(lastStorage=[[9223372036854775807,0,20,6],None]),
        "bad-image-geometry":lambda e:e["state"].update(cellPixels=[0,16]),
        "completed-Kitty-transfer":lambda e:e["state"]["kitty"].update(pendingCommands=[list(b"\x1b_Ga=t,f=32,s=1,v=1,i=1,m=0;/wAA/w==\x1b\\")]),
    }
    expected_errors = {
        "non-sixel-dcs":"bridge token is complete or unsupported",
        "mismatched-image-geometry":"bridge authoritative geometry mismatch",
        "version":"bridge envelope bounds","bad-dimensions":"bridge envelope bounds",
        "oversize-token":"bridge envelope bounds","bad-cell-width":"bridge cell geometry or grapheme",
        "completed-query-as-token":"bridge token is complete or unsupported","oversize-checkpoint":"bridge byte limit",
        "overflow-cursor":"bridge cursor bounds","overflow-cell":"bridge cell geometry or grapheme",
        "invalid-utf8-prefix":"bridge token is complete or unsupported","sequence-limit":"bridge envelope bounds",
        "short-tabs":"bridge envelope bounds","bad-margins":"bridge margin bounds",
        "bad-mouse-mode":"unknown mouse mode",
        "bad-repetitions":"bridge cell geometry or grapheme","bad-last-storage":"bridge last-storage bounds",
        "bad-image-geometry":"bridge image geometry","completed-Kitty-transfer":"bridge Kitty requires unfinished direct transmission",
    }
    for label, mutate in mutations.items():
        value = json.loads(bytes(sample["bytes"]))
        mutate(value)
        request = {"checkpoint":list(json.dumps(value).encode()),"events":[]}
        controls[label] = rejected(request, expected_errors[label])
    image_sample = candidate["iterm-valid-png"]["checkpoints"][0]
    image_twin = {"checkpoint":image_sample["bytes"],"events":[]}
    for label,mutate,diagnostic in [
        ("encoded-image-dimension-mismatch",lambda e:e["state"]["graphics"][0].update(width=3),"bridge encoded image dimensions"),
        ("image-raster-budget",lambda e:e["state"]["graphics"][0].update(displayWidth=2048,displayHeight=2048),"bridge rendered image byte limit"),
        ("missing-image-resource",lambda e:e["state"]["normal"]["lines"][0]["images"][0].update(resource="missing"),"bridge image placement"),
    ]:
        value = json.loads(bytes(image_sample["bytes"]));mutate(value)
        controls[label] = rejected({"checkpoint":list(json.dumps(value).encode()),"events":[]},diagnostic,image_twin)
    fresh_request = {"checkpoint":sample["bytes"],"events":[]}
    fresh = json.loads(run([str(swift)],out / "fresh-template.log",data=json.dumps(fresh_request).encode()))
    dirty_bytes = list(b"old" + "👩‍💻".encode() + b"\x1b[4 q\x1b]4;1;rgb:12/34/56\x07\x1b[>3u")
    dirty_request = dict(fresh_request,dirty=dirty_bytes)
    dirty = json.loads(run([str(swift)],out / "dirty-template.log",data=json.dumps(dirty_request).encode()))
    before_request = {"events":[{"sequence":0,"event":{"data":[]}}]}
    clean_before = json.loads(run([str(swift)],out / "clean-before.log",data=json.dumps(before_request).encode()))
    dirty_before = json.loads(run([str(swift)],out / "dirty-before.log",data=json.dumps(dict(before_request,dirty=dirty_bytes)).encode()))
    clean_state = plistlib.loads(base64.b64decode(clean_before["snapshots"][0]["nativeCheckpoint"]))["state"]
    dirty_state = plistlib.loads(base64.b64decode(dirty_before["snapshots"][0]["nativeCheckpoint"]))["state"]
    positive_controls = {"dirty-template-replaced":dirty["snapshots"] == fresh["snapshots"],
        "dirty-input-confirmed":all([
            clean_before["snapshots"][0]["cells"] != dirty_before["snapshots"][0]["cells"],
            clean_state["ansiColors"] != dirty_state["ansiColors"],
            clean_state["options"]["cursorStyle"] != dirty_state["options"]["cursorStyle"],
            clean_state["keyboardNormal"] != dirty_state["keyboardNormal"],
            bool(dirty_state["graphemes"])])}
    for label, payload, expected in [
        ("truncated-envelope", b'{"version":', "dataCorrupted"),
    ]:
        controls[label] = rejected({"checkpoint":list(payload),"events":[]}, expected)
    for label,payload,expected in [
        ("oversize-stream-line",b"x"*5_000_001,"stream line limit"),
        ("truncated-stream-line",b'{"checkpoint":[]}',"truncated stream line"),
    ]:
        twin = subprocess.run([str(swift),"--stream"],input=json.dumps({"checkpoint":sample["bytes"]}).encode()+b"\n",
            capture_output=True,timeout=10)
        if twin.returncode or not twin.stdout:
            raise RuntimeError("stream negative-control positive twin failed")
        twin_passes += 1
        result = subprocess.run([str(swift),"--stream"],input=payload,capture_output=True,timeout=10)
        controls[label] = result.returncode == 1 and not result.stdout and expected in result.stderr.decode()
    # These are comparison-harness controls built from native checkpoints, not
    # new terminal-engine results. Styled blanks and hidden cells must remain visible.
    source = fresh["snapshots"][0]["nativeCheckpoint"]
    original = plistlib.loads(base64.b64decode(source))
    changed = copy.deepcopy(original)
    line = changed["state"]["normalBuffer"]["lines"][0]
    cells = bytearray(line["cellData"])
    cells[(line["cellCount"]-1)*23+13] ^= 8
    line["cellData"] = bytes(cells)
    encoded = base64.b64encode(plistlib.dumps(changed)).decode()
    positive_controls["styled-blank-difference-visible"] = semantic(source) != semantic(encoded)
    changed = copy.deepcopy(original)
    changed["state"]["currentAttribute"]["style"] ^= 1
    encoded = base64.b64encode(plistlib.dumps(changed)).decode()
    positive_controls["pen-difference-visible"] = semantic(source) != semantic(encoded)
    positive_controls["negative-control-twins"] = twin_passes == len(controls)
    if not all(positive_controls.values()):
        raise RuntimeError(f"native positive control failed: {positive_controls}")
    if not all(controls.values()):
        raise RuntimeError(f"native receiver negative control failed: {controls}")
    long_checkpoint = candidate["long-session"]["checkpoints"][0]
    short_checkpoint = candidate["shorter-session"]["checkpoints"][0]
    if long_checkpoint.get("bytes") != short_checkpoint.get("bytes"):
        raise RuntimeError("steady-state checkpoint grew or changed with repeated discarded output")
    if "limit" not in candidate["token-overflow"]["checkpoints"][0].get("error", ""):
        raise RuntimeError("unfinished-token limit not enforced")
    retained = json.loads((ROOT / "docs/research/myterm-wezterm-feasibility/macos-compatibility/wezterm-traces.json").read_text())
    unchanged_projection = []
    for name, previous in retained.items():
        current = candidate[name]
        for event,(a,b) in enumerate(zip(previous["snapshots"],current["snapshots"],strict=True)):
            fields = [k for k in ["cells","styles","cursor","alt","history","replies"] if a[k]!=b[k]]
            if fields:
                raise RuntimeError(f"checkpoint instrumentation changed the retained projection: {name}/{event}: {fields}")
        unchanged_projection.append(name)
    # The native Rust producer and native Swift importer run concurrently. Rust
    # flushes a committed snapshot before suffix events; its output pipe is the
    # bounded backlog while Swift restores. Nothing injects keyboard/mouse input.
    stream_events = [{"data":list(b"before\x1b[3;4H\x1b[6n"),"checkpoint":True}]
    for i in range(12):
        stream_events += [{"data":list(f"\r\nrow-{i}".encode())}, {"resize":[16 if i%2 else 20,6]}]
    stream_events += [{"data":list(b"\x1b[6n\r\nlast") }]
    stream_fixture = [{"name":"native-handoff","events":stream_events}]
    producer_log = (out / "stream-rust.log").open("wb")
    client_log = (out / "stream-swift.log").open("wb")
    producer = subprocess.Popen([str(rust),"--stream"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=producer_log,env=env)
    client = subprocess.Popen([str(swift),"--stream"],stdin=producer.stdout,stdout=subprocess.PIPE,stderr=client_log)
    producer.stdout.close()
    errors = []
    def feed():
        try:
            producer.stdin.write(json.dumps(stream_fixture).encode())
            producer.stdin.close()
        except (OSError, ValueError) as error:
            errors.append(str(error))
    feeder = threading.Thread(target=feed)
    feeder.start()
    try:
        stream_output, _ = client.communicate(timeout=60)
        producer.wait(timeout=10)
    except subprocess.TimeoutExpired:
        client.kill(); producer.kill()
        client.wait(); producer.wait()
        raise
    finally:
        feeder.join(timeout=5)
        producer_log.close(); client_log.close()
    if errors or producer.returncode or client.returncode or feeder.is_alive():
        raise RuntimeError(f"native handoff failed: producer={producer.returncode} client={client.returncode} feed={errors}")
    streamed = json.loads(stream_output)
    reference = json.loads(run([str(swift)],out / "stream-reference.log",data=json.dumps({
        "events":[{"sequence":i,"event":e} for i,e in enumerate(stream_events)]}).encode()))
    stream_differences = []
    previous_replies = reference["snapshots"][0]["replies"]
    for i,(a,b) in enumerate(zip(reference["snapshots"],streamed["snapshots"],strict=True)):
        fields = [k for k in ["cells","styles","cursor","alt","history"] if a[k]!=b[k]]
        if a["replies"][len(previous_replies):] != b["replies"]:
            fields.append("replies")
        if fields: stream_differences.append({"event":i,"fields":fields})
    (out / "native-stream.json").write_text(json.dumps({"reference":reference,"restored":streamed,"differences":stream_differences}))
    from checkpoint_pty_checks import check_live_pty
    live_pty = check_live_pty(out,rust,swift)
    return {"cases":cases,"exporterBoundaryControls":boundary_controls,"negativeControls":controls,"positiveControls":positive_controls,"unchangedEngineProjections":unchanged_projection,"livePty":live_pty,
        "boundedOutput":{"inputLines":[1000,10000],"identicalCheckpointBytes":long_checkpoint["size"]},
        "nativeStream":{"events":len(stream_events),"differences":stream_differences,
            "passed":not stream_differences,"transport":"concurrent native processes over OS pipe; not PTY/network"},"summary":{
        "passed":sum(c["status"]=="passed" for c in cases),
        "failed":sum(c["status"].startswith("failed") for c in cases),
        "unsupported":sum(c["status"]=="unsupported" for c in cases),
        "rejectedLimits":sum(c["status"]=="rejected-limit" for c in cases),
        "negativeControls":len(controls),"nativeStreamPassed":not stream_differences,"livePtyPassed":live_pty["passed"],"maximumCheckpointBytes":max(checkpoints,default=0),
        "maximumImportNs":max(imports,default=0)}}
