"""Real native integration and measurement runner; no GUI automation."""
import argparse
from collections import deque
import base64
import datetime
import json
import os
from pathlib import Path
import platform
import queue
import secrets
import signal
import subprocess
import sys
import threading
import time

HERE = Path(__file__).resolve().parent


def percentile(values, fraction=.95):
    if not values:
        raise RuntimeError("missing measurement samples")
    return sorted(values)[min(len(values) - 1, int(len(values) * fraction))]


class Client:
    def __init__(self, binary, name, directory):
        self.name = name
        self.stderr = (directory / f"{name}.stderr").open("w")
        self.process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.stderr, text=True, bufsize=1)
        self.messages = queue.Queue()
        self.acks = {}
        self.events = []
        self.counter = 0
        self.imports = {}
        self.disconnected = set()
        self.echoes = {}
        self.echo_order = deque()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        try:
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
        except Exception as error:
            self.messages.put({"kind": "fatal", "error": str(error)})
        self.messages.put({"kind": "processExit"})

    def pump(self, wait=0):
        try:
            message = self.messages.get(timeout=wait)
        except queue.Empty:
            return
        kind = message.get("kind")
        if kind in ("fatal", "connectionFailed", "sendError", "processExit"):
            raise RuntimeError(f"{self.name}: {message}")
        if kind == "ack":
            self.acks[message["id"]] = message
        elif kind == "imported":
            key = (message["server"], message["session"])
            self.imports[key] = self.imports.get(key, 0) + 1
        elif kind == "echo":
            key = (message["server"], message["session"], message["marker"])
            self.echoes[key] = (message["pid"], message["receivedUptimeNs"])
            self.echo_order.append(key)
            while len(self.echo_order) > 4096:
                self.echoes.pop(self.echo_order.popleft(), None)
        elif kind != "closed":
            self.events.append(message)

    def send(self, action, server="a", **kwargs):
        self.counter += 1
        request = {"id": self.counter, "action": action, "server": server, **kwargs}
        self.process.stdin.write(json.dumps(request) + "\n")
        self.process.stdin.flush()
        return self.counter

    def wait(self, identifier, *, accepted=True, timeout=10, error=None):
        deadline = time.monotonic() + timeout
        while identifier not in self.acks:
            if time.monotonic() > deadline:
                raise RuntimeError(f"{self.name}: acknowledgement timeout for {identifier}")
            self.pump(.05)
        response = self.acks.pop(identifier)
        if accepted is not None and response["ok"] != accepted:
            raise RuntimeError(f"{self.name}: unexpected response {response}")
        if error is not None and response.get("error") != error:
            raise RuntimeError(f"{self.name}: wrong rejection reason {response}")
        return response.get("result", response)

    def call(self, action, server="a", *, accepted=True, error=None, **kwargs):
        result = self.wait(self.send(action, server, **kwargs), accepted=accepted, error=error)
        if action == "disconnect":
            self.disconnected.add(server)
        if action == "connect" and accepted:
            self.disconnected.discard(server)
        return result

    def imported(self, server, sid, previous):
        deadline = time.monotonic() + 10
        while self.imports.get((server, sid), 0) <= previous:
            if time.monotonic() > deadline:
                raise RuntimeError(f"{self.name}: native import timeout")
            self.pump(.05)

    def subscribe(self, server, sid, enabled=True):
        previous = self.imports.get((server, sid), 0)
        self.call("subscribe", server, session=sid, enabled=enabled)
        if enabled:
            self.imported(server, sid, previous)
            # A status round trip follows the native import's synchronization acknowledgement.
            self.call("status", server)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.stderr.close()


class Experiment:
    def __init__(self, build, out, bound):
        self.build, self.out, self.bound = build, out, bound
        self.servers = {}
        self.logs = []
        self.clients = []
        self.keys = {name: secrets.token_hex(32) for name in ["one", "two"]}
        try:
            self.start()
        except BaseException:
            self.close()
            raise

    def start(self):
        build, out, bound = self.build, self.out, self.bound
        for name in ["a", "b"]:
            log = (out / f"server-{name}.stderr").open("w")
            self.logs.append(log)
            process = subprocess.Popen([str(build / "server"), "--handoff"], stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=log, text=True)
            process.stdin.write(json.dumps({"python": sys.executable, "workload": str(HERE / "workload.py"),
                                            "queue": bound, "clients": self.keys}) + "\n")
            process.stdin.flush()
            # A bounded read also detects a server that fails before its listener is ready.
            ready = queue.Queue()
            threading.Thread(target=lambda p=process, q=ready: q.put(p.stdout.readline()), daemon=True).start()
            boot = json.loads(ready.get(timeout=15))
            self.servers[name] = (process, boot)
        for name in ["one", "two"]:
            client = Client(build / "client", name, out)
            self.clients.append(client)
            for server in self.servers:
                self.connect(client, server, 0)
                for sid in [0, 1]:
                    client.subscribe(server, sid)
        self.revisions = {}
        self.initial_pids = {name: boot["pids"] for name, (_, boot) in self.servers.items()}

    def connect(self, client, server, generation, *, action="connect", valid=True):
        boot = self.servers[server][1]
        return client.call(action, server, port=boot["port"], certificate=boot["certificate"],
                           client=client.name, capability=self.keys[client.name] if valid else "rejected-test-value",
                           expectedGeneration=generation, accepted=valid)

    def state(self, server="a", sid=0):
        client = next(c for c in self.clients if server not in c.disconnected)
        return client.call("status", server)["sessions"][sid]

    def take(self, client, server="a", sid=0, *, expected=None, accepted=True, cols=120, rows=40):
        state = expected or self.state(server, sid)
        result = client.call("take", server, session=sid, expectedOwner=state["owner"],
                             revision=state["revision"], cols=cols, rows=rows, accepted=accepted)
        return result

    def input(self, client, server="a", sid=0, *, revision=None, accepted=True, **command):
        if revision is None:
            revision = self.state(server, sid)["revision"]
        raw = json.dumps(command).encode() + b"\n"
        return client.call("input", server, session=sid, revision=revision,
                           data=base64.b64encode(raw).decode(), accepted=accepted)

    def wait_echo(self, client, marker, server="a", sid=0):
        deadline = time.monotonic() + 10
        while True:
            key = (server, sid, marker)
            if key in client.echoes:
                pid, timestamp = client.echoes.pop(key)
                assert pid == self.initial_pids[server][sid], ("actual workload echo PID changed", pid)
                return timestamp
            if time.monotonic() > deadline:
                raise RuntimeError("real PTY input/output echo timeout")
            client.pump(.01)

    def check_pids(self):
        for server, pids in self.initial_pids.items():
            actual = [s["pid"] for s in self.clients[0].call("status", server)["sessions"]]
            assert actual == pids, (actual, pids)
            assert all(s["rejectedWorkloadEchoes"] == 0 for s in self.clients[0].call("status", server)["sessions"]), "rejected input executed by the PTY workload"

    def metrics(self):
        result = {}
        pids = [c.process.pid for c in self.clients]
        for server, (process, boot) in self.servers.items():
            if process.poll() is not None:
                raise RuntimeError(f"server {server} exited {process.returncode}")
            pids += [process.pid, *boot["pids"]]
            result[server] = self.clients[0].call("status", server)
        listing = subprocess.check_output(["ps", "-o", "pid=,rss=,time=", "-p", ",".join(map(str, pids))], text=True)
        result["processes"] = []
        for line in listing.splitlines():
            pid, rss, cpu_time = line.split()
            seconds = sum(float(part) * 60 ** index for index, part in enumerate(reversed(cpu_time.split(":"))))
            result["processes"].append({"pid": int(pid), "rssKiB": int(rss), "cpuTimeSeconds": seconds})
        return result

    def close(self):
        for server, (process, _) in self.servers.items():
            if process.poll() is None:
                for client in self.clients:
                    if client.process.poll() is None and server not in client.disconnected:
                        try:
                            client.call("pause", server, paused=False)
                            client.call("stop", server)
                            process.wait(timeout=5)
                            break
                        except (RuntimeError, BrokenPipeError, subprocess.TimeoutExpired):
                            continue
        for client in self.clients:
            client.close()
        for process, boot in self.servers.values():
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            # A terminated parent cannot run Rust's destructor. Check identity before fallback cleanup.
            for pid in boot["pids"]:
                status = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True)
                if str(HERE / "workload.py") in status.stdout:
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        for log in self.logs:
            log.close()


def regression(exp, cycles):
    one, two = exp.clients
    checks = []
    def checked(name):
        checks.append(name)
    original = exp.state()
    assert original["owner"] is None
    checked("selection/subscription does not acquire control")
    state = exp.take(one)
    one.call("synchronized", session=0, syncToken=0, accepted=False, error="stale synchronization token")
    checked("stale synchronization acknowledgements cannot reopen input")
    exp.input(one, echo="first-native-input")
    exp.wait_echo(one, "first-native-input")
    checked("accepted controller input reaches the real PTY")
    exp.take(two, expected=original, accepted=False)
    exp.input(two, revision=original["revision"], accepted=False, echo="rejected-input")
    raw = base64.b64encode(b'{"echo":"bypassed-native-gate"}\n').decode()
    two.call("rawInput", session=0, revision=original["revision"], data=raw, accepted=False, error="not current controller")
    checked("stale takeover and viewer input rejected")
    takeover_times, replacement_times, switch_times = [], [], []
    for cycle in range(cycles):
        prior = exp.state()
        start = time.perf_counter()
        identifiers = [c.send("take", session=0, expectedOwner=prior["owner"], revision=prior["revision"], cols=120, rows=40)
                       for c in [one, two]]
        responses = [c.wait(i, accepted=None) for c, i in zip([one, two], identifiers)]
        assert sum("error" not in response for response in responses) == 1
        takeover_times.append((time.perf_counter() - start) * 1000)
        current = exp.state()
        owner = one if current["owner"] == "one" else two
        viewer = two if owner is one else one
        before = current["inputCount"]
        exp.input(viewer, revision=prior["revision"], accepted=False, echo="displaced-input")
        viewer.call("rawInput", session=0, revision=prior["revision"], data=raw, accepted=False, error="not current controller")
        assert exp.state()["inputCount"] == before
        # Ownership can return to the same endpoint, but an older revision remains stale.
        exp.take(viewer)
        exp.take(owner)
        exp.take(viewer, expected=current, accepted=False)
        # Switching subscriptions preserves the controller, including while it has no output subscription.
        owned = exp.state()
        start = time.perf_counter()
        owner.subscribe("a", 0, False)
        assert exp.state()["owner"] == owned["owner"]
        owner.call("rawInput", session=0, revision=owned["revision"], data=raw, accepted=False,
                   error="input gated during synchronization")
        owner.subscribe("a", 1, True)
        owner.subscribe("a", 1, False)
        owner.subscribe("a", 0, True)
        switch_times.append((time.perf_counter() - start) * 1000)
        # A failed separate TLS candidate must not replace the working channel.
        generation = owner.call("inspect", session=0)["generation"]
        exp.connect(owner, "a", generation, action="candidate", valid=False)
        exp.connect(owner, "a", generation, action="candidate", valid=True)
        exp.input(owner, echo=f"after-rejected-candidate-{cycle}")
        exp.wait_echo(owner, f"after-rejected-candidate-{cycle}")
        start = time.perf_counter()
        exp.connect(owner, "a", generation)
        owner.subscribe("a", 0)
        replacement_times.append((time.perf_counter() - start) * 1000)
        exp.input(owner, echo=f"after-replacement-{cycle}")
        exp.wait_echo(owner, f"after-replacement-{cycle}")
        # Disconnect does not release ownership; viewers can explicitly take it while absent.
        generation = owner.call("inspect", session=0)["generation"]
        owner.call("disconnect")
        viewer_state = viewer.call("status")["sessions"][0]
        assert viewer_state["owner"] == owner.name
        exp.take(viewer)
        exp.connect(owner, "a", generation)
        owner.subscribe("a", 0)
        exp.input(owner, accepted=False, echo="absent-controller-input")
        exp.check_pids()
        if (cycle + 1) % 10 == 0:
            print(json.dumps({"controlCycles": cycle + 1}), flush=True)
    checked(f"{cycles} competing takeovers have exactly one winner")
    checked(f"{cycles} displaced input and away/back stale revision checks")
    checked(f"{cycles} subscription switches preserve ownership")
    checked(f"{cycles} rejected TLS candidates leave prior channel usable")
    checked(f"{cycles} TLS replacements resume synchronized PTY input")
    checked(f"{cycles} disconnected owners can be displaced without stopping processes")
    owner = one if exp.state()["owner"] == "one" else two
    state = exp.state()
    owner.call("release", session=0, revision=state["revision"])
    assert exp.state()["owner"] is None
    checked("explicit release leaves everyone viewing")
    return {"checks": checks, "cycles": cycles,
            "takeoverMs": takeover_times, "switchSyncMs": switch_times,
            "replacementSyncMs": replacement_times}


def load(exp, seconds, rate, policy, slow_seconds, during_load_cycles=0):
    one, two = exp.clients
    before = time.perf_counter_ns()
    clock = one.call("inspect", session=0)["clockUptimeNs"]
    after = time.perf_counter_ns()
    assert before <= clock <= after, "native and runner monotonic clocks do not share the measured epoch"
    for server in ["a", "b"]:
        for sid in [0, 1]:
            one.subscribe(server, sid)
            two.subscribe(server, sid)
            exp.take(one, server, sid)
            exp.input(one, server, sid, rate=rate)
    if policy == "visible":
        for client in [one, two]:
            for server in ["a", "b"]:
                client.subscribe(server, 1, False)
    samples, echoes = [], []
    start = time.monotonic()
    paused = resumed = False
    controls = []
    while time.monotonic() - start < seconds:
        elapsed = time.monotonic() - start
        if slow_seconds and elapsed >= 5 and not paused:
            two.call("pause", paused=True); paused = True
        if paused and not resumed and elapsed >= 5 + slow_seconds:
            two.call("pause", paused=False); resumed = True
        if during_load_cycles and elapsed >= 40 + len(controls) * max(1, (seconds - 60) / during_load_cycles) and len(controls) < during_load_cycles:
            begin = time.perf_counter()
            exp.take(two)
            exp.input(one, accepted=False, echo="stress-displaced-input")
            exp.take(one)
            one.subscribe("a", 0, False)
            one.subscribe("a", 1)
            one.subscribe("a", 1, policy == "continuous")
            one.subscribe("a", 0)
            generation = one.call("inspect", session=0)["generation"]
            exp.connect(one, "a", generation, action="candidate", valid=False)
            exp.connect(one, "a", generation, action="candidate", valid=True)
            exp.connect(one, "a", generation)
            one.subscribe("a", 0)
            if policy == "continuous":
                one.subscribe("a", 1)
            exp.check_pids()
            controls.append({"at": elapsed, "ms": (time.perf_counter() - begin) * 1000})
            with (exp.out / "loaded-controls.jsonl").open("a") as evidence:
                evidence.write(json.dumps(controls[-1]) + "\n")
        marker = f"load-{len(echoes)}"
        revision = exp.state()["revision"]
        begin = time.perf_counter_ns()
        exp.input(one, revision=revision, echo=marker)
        try:
            arrived = exp.wait_echo(one, marker)
        except RuntimeError as error:
            try:
                (exp.out / "echo-timeout-state.json").write_text(json.dumps(exp.metrics(), indent=2) + "\n")
            except Exception as diagnostic:
                (exp.out / "echo-timeout-diagnostic-error.json").write_text(json.dumps({"original": str(error), "diagnostic": str(diagnostic)}) + "\n")
            raise
        assert arrived >= begin, "native echo preceded input"
        echoes.append({"at": elapsed, "ms": (arrived - begin) / 1_000_000})
        samples.append({"at": time.monotonic() - start, **exp.metrics()})
        with (exp.out / "samples.jsonl").open("a") as evidence:
            evidence.write(json.dumps(samples[-1]) + "\n")
        with (exp.out / "echoes.jsonl").open("a") as evidence:
            evidence.write(json.dumps(echoes[-1]) + "\n")
        if len(samples) % 15 == 0:
            print(json.dumps({"progressSeconds": round(elapsed), "policy": policy, "rate": rate}), flush=True)
        time.sleep(.2)
    if paused and not resumed:
        two.call("pause", paused=False)
    # Stop production before asking both independent native parsers to verify their final state.
    for server in ["a", "b"]:
        for sid in [0, 1]:
            if policy == "visible" and sid == 1:
                one.subscribe(server, sid)
            exp.input(one, server, sid, rate=0)
    time.sleep(.5)
    parity = []
    for client in [one, two]:
        for server in ["a", "b"]:
            for sid in [0, 1]:
                if policy == "visible" and sid == 1:
                    client.subscribe(server, sid)
                previous = client.imports.get((server, sid), 0)
                client.call("checkpoint", server, session=sid)
                client.imported(server, sid, previous)
                parity.append({"client": client.name, "server": server, "session": sid,
                               "result": client.call("inspect", server, session=sid, snapshot=True)})
    exp.check_pids()
    for server in ["a", "b"]:
        states = exp.clients[0].call("status", server)["sessions"]
        for sid, state in enumerate(states):
            views = [p["result"] for p in parity if p["server"] == server and p["session"] == sid]
            assert all(v["hash"] == state["hash"] and v["sequence"] == state["sequence"] for v in views), "final native delivery cut differs"
            assert all(v["parityChecks"] > 0 for v in views), "no incremental/import native parity check"
            for view in views:
                view["snapshot"].pop("replies", None)
            assert views[0]["snapshot"] == views[1]["snapshot"], "two native clients differ"
    return {"seconds": seconds, "rate": rate, "policy": policy, "slowSeconds": slow_seconds,
            "samples": samples, "echoMs": echoes, "loadedControls": controls, "finalNativeState": parity,
            "finalNativeParityAsserted": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cycles", type=int, default=2)
    parser.add_argument("--seconds", type=int, default=10)
    parser.add_argument("--rate", type=int, default=10240)
    parser.add_argument("--policy", choices=["visible", "continuous"], default="visible")
    parser.add_argument("--queue", type=int, choices=[262144,1048576,4194304], default=1048576)
    parser.add_argument("--slow-seconds", type=int, default=0)
    parser.add_argument("--during-load-cycles", type=int, default=0)
    args = parser.parse_args()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=False)
    metadata = {"startedUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "environment": platform.platform(), "arguments": {k: str(v) if isinstance(v, Path) else v for k,v in vars(args).items()},
                "scope": "native Mac PTY + TLS + headless TerminalView; visible UI and production trust unverified"}
    metadata["build"] = json.loads((args.build / "build.json").read_text())
    (out / "run.json").write_text(json.dumps(metadata, indent=2) + "\n")
    experiment = None
    try:
        experiment = Experiment(args.build.resolve(), out, args.queue)
        result = {"regression": regression(experiment, args.cycles)}
        (out / "regression.json").write_text(json.dumps(result, indent=2) + "\n")
        if args.seconds:
            result["load"] = load(experiment, args.seconds, args.rate, args.policy, args.slow_seconds, args.during_load_cycles)
        experiment.close()
        experiment = None
        result["completed"] = True
        (out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({"completed": True, "output": str(out)}), flush=True)
    except Exception as error:
        (out / "failure.json").write_text(json.dumps({"error": str(error)}, indent=2) + "\n")
        raise
    finally:
        if experiment:
            experiment.close()


if __name__ == "__main__":
    main()
