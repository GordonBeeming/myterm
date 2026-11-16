"""Launch two disposable native review apps. GUI opt-in is required before running."""
import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import threading
import time

from run import Client, Experiment


class AppProcess:
    def __init__(self, pid, writer, marker):
        self.pid, self.stdin, self.marker = pid, writer, marker
        self.next_check = 0
        self.exited = False

    def poll(self):
        if self.exited:
            return 0
        now = time.monotonic()
        if now < self.next_check:
            return None
        self.next_check = now + .5
        state = subprocess.run(["ps", "-o", "command=", "-p", str(self.pid)], capture_output=True, text=True)
        self.exited = self.marker not in state.stdout
        return 0 if self.exited else None

    def wait(self, timeout=5):
        deadline = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() > deadline:
                raise subprocess.TimeoutExpired("native review app", timeout)
            time.sleep(.05)
        return 0

    def kill(self):
        state = subprocess.run(["ps", "-o", "command=", "-p", str(self.pid)], capture_output=True, text=True)
        if self.marker in state.stdout:
            os.kill(self.pid, signal.SIGKILL)


class GuiClient(Client):
    def __init__(self, binary, name, directory):
        self.name = name
        fifo = directory / f"{name}.commands.fifo"
        os.mkfifo(fifo, 0o600)
        writer = os.fdopen(os.open(fifo, os.O_RDWR), "w", buffering=1)
        output = directory / f"{name}.messages.jsonl"
        output.touch()
        error = directory / f"{name}.stderr"
        self.stderr = error.open("a")
        self.log = output.open()
        try:
            subprocess.run(["/usr/bin/open", "-n", str(binary.parent / "HandoffReview.app"),
                            "--stdout", str(output), "--stderr", str(error),
                            "--args", "--gui", "--input-fifo", str(fifo)], check=True)
            deadline = time.monotonic() + 15
            while True:
                listing = subprocess.check_output(["ps", "-ax", "-o", "pid=,command="], text=True)
                matches = [int(line.split(maxsplit=1)[0]) for line in listing.splitlines()
                           if "HandoffReview" in line and str(fifo) in line]
                if len(matches) == 1:
                    break
                if time.monotonic() > deadline:
                    raise RuntimeError(f"native review app did not appear: {name}")
                time.sleep(.05)
            self.process = AppProcess(matches[0], writer, str(fifo))
        except BaseException as original:
            writer.close()
            try:
                listing = subprocess.check_output(["ps", "-ax", "-o", "pid=,command="], text=True)
                for line in listing.splitlines():
                    if "HandoffReview" in line and str(fifo) in line:
                        try:
                            os.kill(int(line.split(maxsplit=1)[0]), signal.SIGTERM)
                        except ProcessLookupError:
                            continue
            except Exception as cleanup:
                raise BaseExceptionGroup("native review startup and cleanup failed", [original, cleanup])
            finally:
                self.log.close(); self.stderr.close()
            raise
        self.messages = queue.Queue()
        self.acks, self.events, self.imports, self.echoes = {}, [], {}, {}
        from collections import deque
        self.echo_order = deque()
        self.disconnected = set()
        self.counter = 0
        threading.Thread(target=self.read, daemon=True).start()
        print(json.dumps({"stage": "before-connect", "client": name, "pid": self.process.pid,
                          "instruction": 'Capture the empty native window; send {"action":"continue"}.'}), flush=True)
        choice = sys.stdin.readline()
        try:
            accepted = bool(choice) and json.loads(choice) == {"action": "continue"}
        except json.JSONDecodeError:
            accepted = False
        if not accepted:
            self.close()
            raise RuntimeError('native review preparation requires {"action":"continue"}')

    def read(self):
        pending = ""
        try:
            while self.process.poll() is None:
                if os.fstat(self.log.fileno()).st_size > 64 * 1024 * 1024:
                    self.process.stdin.close()
                    raise RuntimeError("native review evidence exceeded the 64 MiB bound")
                line = self.log.readline()
                if line:
                    pending += line
                    if len(pending) > 2_000_000:
                        raise RuntimeError("native review message bound")
                    if pending.endswith("\n"):
                        self.messages.put(json.loads(pending))
                        pending = ""
                else:
                    time.sleep(.02)
        except Exception as error:
            self.messages.put({"kind": "fatal", "error": str(error)})
        self.messages.put({"kind": "processExit"})

    def close(self):
        super().close()
        self.log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--rate", type=int, default=10240)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    experiment = Experiment(args.build.resolve(), out, 1048576, client_factory=GuiClient)
    try:
        one, two = experiment.clients
        for server in ("a", "b"):
            for client in (one, two):
                client.subscribe(server, 1, False)
            experiment.take(one, server, 0)
            for sid in (0, 1):
                if sid == 1:
                    one.subscribe(server, sid)
                    experiment.take(one, server, sid)
                experiment.input(one, server, sid, rate=args.rate)
                if sid == 1:
                    one.subscribe(server, sid, False)
        print(json.dumps({"stage": "native-review-ready", "clients": [c.process.pid for c in experiment.clients]}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("action") == "quit":
                break
            if request.get("action") == "status":
                print(json.dumps({"metrics": experiment.metrics()}), flush=True)
            elif request.get("action") == "workload":
                client = one if request.pop("client", "one") == "one" else two
                server = request.pop("server", "a")
                sid = request.pop("session", 0)
                request.pop("action")
                experiment.input(client, server, sid, **request)
                print(json.dumps({"workloadUpdated": True}), flush=True)
            else:
                client = one if request.pop("client", "one") == "one" else two
                action = request.pop("action")
                server = request.pop("server", "a")
                print(json.dumps({"result": client.call(action, server, **request)}), flush=True)
    finally:
        experiment.close()


if __name__ == "__main__":
    main()
