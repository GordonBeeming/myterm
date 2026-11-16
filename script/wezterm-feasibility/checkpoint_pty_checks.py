"""Real PTY shell survives a native fresh-client checkpoint import and resize."""
import json
import os
import select
import signal
import subprocess
import time

from run import run
from checkpoint_checks import semantic


def check_live_pty(out, rust, swift):
    buffers = {}
    def line(pipe, timeout=10):
        data = buffers.pop(pipe.fileno(), b"")
        deadline = time.monotonic()+timeout
        while b"\n" not in data:
            remaining = deadline-time.monotonic()
            if remaining <= 0 or not select.select([pipe],[],[],max(0,remaining))[0]:
                raise RuntimeError("native PTY protocol line timeout")
            chunk = os.read(pipe.fileno(),4096)
            if not chunk:
                raise RuntimeError("native PTY protocol EOF")
            data += chunk
            if len(data)>5_000_000:
                raise RuntimeError("native PTY protocol line bound")
        value,rest = data.split(b"\n",1)
        buffers[pipe.fileno()] = rest
        return value

    pid = None
    source = None
    client = None
    evidence = None
    with (out/"live-pty-rust.log").open("wb") as source_log, (out/"live-pty-swift.log").open("wb") as client_log:
        try:
            source = subprocess.Popen([str(rust),"--live-pty"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=source_log)
            header = json.loads(line(source.stdout))
            pid = header["pid"]
            client = subprocess.Popen([str(swift),"--stream","--import-ack"],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=client_log)
            client.stdin.write(json.dumps(header).encode()+b"\n");client.stdin.flush()
            ack = json.loads(line(client.stdout))
            if ack["imported"] != header["cut"]:
                raise RuntimeError("native PTY checkpoint import acknowledgement differs")
            source.stdin.write(b"continue\n");source.stdin.flush();source.stdin.close();source.stdin=None
            while True:
                data = line(source.stdout)
                value = json.loads(data)
                if "ptyEvidence" in value:
                    evidence = value["ptyEvidence"]
                    break
                client.stdin.write(data+b"\n");client.stdin.flush()
            client.stdin.close();client.stdin=None
            output,_ = client.communicate(timeout=10)
            source.wait(timeout=5)
            if source.returncode or client.returncode:
                raise RuntimeError(f"native PTY process failed: rust={source.returncode}, swift={client.returncode}")
            restored = json.loads(output)
        finally:
            for process in [client,source]:
                if process is not None and process.poll() is None:
                    process.kill();process.wait()
            if pid is not None and (evidence is None or not evidence.get("childExitedSuccessfully")):
                try:
                    if os.getpgid(pid)==pid:
                        os.killpg(pid,signal.SIGKILL)
                except ProcessLookupError:
                    pass
    events = [{"sequence":i,"event":event} for i,event in enumerate(evidence["events"])]
    reference = json.loads(run([str(swift)],out/"live-pty-reference.log",data=json.dumps({"events":events}).encode()))
    expected = reference["snapshots"][evidence["cut"]:]
    old_replies = expected[0]["replies"]
    differences = []
    for index,(a,b) in enumerate(zip(expected,restored["snapshots"],strict=True)):
        fields = [key for key in ["cells","styles","cursor","alt","history"] if a[key]!=b[key]]
        if a["replies"][len(old_replies):] != b["replies"]:
            fields.append("replies")
        before,after = semantic(a["nativeCheckpoint"]),semantic(b["nativeCheckpoint"])
        fields += ["state."+key for key in before if before[key]!=after[key]]
        if fields:
            differences.append({"offset":index,"fields":fields})
    passed = not differences and evidence["sameShellAfterImport"] and evidence["childExitedSuccessfully"]
    result = {"passed":passed,"differences":differences,"evidence":evidence,"importAcknowledgement":ack,
        "reference":reference,"restored":restored,
        "scope":"real native PTY, one live Rust owner, native fresh client; local IPC, no network or multi-Mac acceptance"}
    (out/"live-pty.json").write_text(json.dumps(result))
    if not passed:
        raise RuntimeError(f"live PTY checkpoint continuation differs: {differences}")
    return {"passed":True,"sameShellAfterImport":True,"pid":pid,"events":len(events),
        "actualResize":evidence["actualResize"],"queryResponses":2,"childExitedSuccessfully":True}
