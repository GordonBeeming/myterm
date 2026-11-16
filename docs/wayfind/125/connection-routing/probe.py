#!/usr/bin/env python3
"""Disposable loopback routing experiment; no production MyTerm integration."""
import argparse
import asyncio
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import ssl
import subprocess
import tempfile
import time


def certificate(root, name):
    key, cert = root / f"{name}.key", root / f"{name}.pem"
    subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "1",
        "-subj", f"/CN={name}", "-addext", "subjectAltName=DNS:localhost",
    ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key.chmod(0o600)
    der = ssl.PEM_cert_to_DER_cert(cert.read_text())
    return cert, key, hashlib.sha256(der).hexdigest()


@dataclass
class Connection:
    route: str
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    ready: dict
    elapsed_ms: float

    async def request(self, action, **fields):
        self.writer.write(json.dumps({"action": action, **fields}).encode() + b"\n")
        await self.writer.drain()
        line = await asyncio.wait_for(self.reader.readline(), 1)
        if not line:
            raise ConnectionError("route closed")
        return json.loads(line)

    async def close(self):
        self.writer.close()
        try:
            await self.writer.wait_closed()
        except (ConnectionError, ssl.SSLError):
            pass  # A deliberately broken fixture route can fail TLS shutdown.


class Fixture:
    def __init__(self, root):
        self.root = root
        self.listeners = []
        self.active = set()
        self.handlers = set()
        self.shell_lock = asyncio.Lock()
        self.controller = "client-a"
        self.attempts = {name: 0 for name in ("local", "direct", "relay", "rogue")}
        self.delays = {"local": 0.01, "direct": 0.06, "relay": 0.12}
        self.session = "disposable-session"
        self.transport_failures = []
        self.shell = None

    async def start(self):
        certs = {name: certificate(self.root, name) for name in ("server", "client-a", "client-b", "rogue")}
        self.clients = {certs[name][2]: name for name in ("client-a", "client-b")}
        self.client_contexts = {}
        for name in ("client-a", "client-b"):
            ctx = ssl.create_default_context(cafile=str(certs["server"][0]))
            ctx.minimum_version = ssl.TLSVersion.TLSv1_3
            ctx.load_cert_chain(*map(str, certs[name][:2]))
            self.client_contexts[name] = ctx
        self.server_pin = certs["server"][2]
        def server_context(name):
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.minimum_version = ssl.TLSVersion.TLSv1_3
            ctx.load_cert_chain(*map(str, certs[name][:2]))
            ctx.verify_mode = ssl.CERT_REQUIRED
            for client in ("client-a", "client-b"):
                ctx.load_verify_locations(str(certs[client][0]))
            return ctx
        self.shell = await asyncio.create_subprocess_exec(
            "/bin/sh", "-c", 'counter=0; while IFS= read -r line; do counter=$((counter+1)); printf "%s:%s:%s\\n" "$$" "$counter" "$line"; done',
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        )
        self.sock = str(self.root / "local.sock")
        self.server_context = server_context("server")
        self.listeners.append(await asyncio.start_unix_server(
            lambda r, w: self.serve(r, w, "local"), self.sock, ssl=self.server_context))
        direct = await asyncio.start_server(
            lambda r, w: self.serve(r, w, "direct"), "127.0.0.1", 0, ssl=server_context("server"))
        self.listeners.append(direct)
        self.direct_port = direct.sockets[0].getsockname()[1]
        relay = await asyncio.start_server(self.forward, "127.0.0.1", 0)
        self.listeners.append(relay)
        self.relay_port = relay.sockets[0].getsockname()[1]
        rogue = await asyncio.start_server(
            lambda r, w: self.serve(r, w, "rogue"), "127.0.0.1", 0, ssl=server_context("rogue"))
        self.listeners.append(rogue)
        self.rogue_port = rogue.sockets[0].getsockname()[1]
        for name in ("rogue-client", "missing-client"):
            ctx = ssl.create_default_context(cafile=str(certs["server"][0]))
            ctx.minimum_version = ssl.TLSVersion.TLSv1_3
            if name == "rogue-client":
                ctx.load_cert_chain(*map(str, certs["rogue"][:2]))
            self.client_contexts[name] = ctx
        return self

    async def serve(self, reader, writer, route):
        task = asyncio.current_task()
        self.handlers.add(task)
        self.active.add(writer)
        try:
            peer = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
            client = self.clients.get(hashlib.sha256(peer).hexdigest())
            if client is None:
                return
            while line := await reader.readline():
                request = json.loads(line)
                if request["action"] == "attach":
                    await asyncio.sleep(self.delays.get(route, 0))
                    reply = {"session": self.session, "pid": self.shell.pid, "controller": self.controller}
                elif request["action"] == "write" and client == self.controller:
                    text = request["text"]
                    if "\n" in text or len(text) > 1000:
                        raise ValueError("fixture input must be one bounded line")
                    async with self.shell_lock:
                        self.shell.stdin.write(text.encode() + b"\n")
                        await self.shell.stdin.drain()
                        result = await asyncio.wait_for(self.shell.stdout.readline(), 1)
                    reply = {"output": result.decode().strip(), "controller": self.controller}
                elif request["action"] == "write":
                    reply = {"error": "viewer", "controller": self.controller}
                else:
                    raise ValueError("unknown fixture action")
                writer.write(json.dumps(reply).encode() + b"\n")
                await writer.drain()
        except (ConnectionError, ssl.SSLError, ValueError, TimeoutError):
            pass  # Negative cases deliberately close peers or submit invalid requests.
        finally:
            self.active.discard(writer)
            writer.close()
            self.handlers.discard(task)

    async def forward(self, reader, writer):
        task = asyncio.current_task()
        self.handlers.add(task)
        upstream = None
        pumps = []
        try:
            await asyncio.sleep(self.delays["relay"])
            remote, upstream = await asyncio.open_connection("127.0.0.1", self.direct_port)
            async def pump(source, target):
                while data := await source.read(65536):
                    target.write(data)
                    await target.drain()
            pumps = [asyncio.create_task(pump(reader, upstream)), asyncio.create_task(pump(remote, writer))]
            await asyncio.wait(pumps, return_when=asyncio.FIRST_COMPLETED)
        except OSError as error:
            self.transport_failures.append(type(error).__name__)
        finally:
            for pump_task in pumps:
                pump_task.cancel()
            await asyncio.gather(*pumps, return_exceptions=True)
            writer.close()
            if upstream:
                upstream.close()
            self.handlers.discard(task)

    async def connect(self, route, client="client-a", timeout=0.7, expected_pin=None):
        self.attempts[route] += 1
        started = time.perf_counter()
        writer = None
        try:
            async with asyncio.timeout(timeout):
                options = {"ssl": self.client_contexts[client], "server_hostname": "localhost"}
                if route == "local":
                    reader, writer = await asyncio.open_unix_connection(self.sock, **options)
                else:
                    port = {"direct": self.direct_port, "relay": self.relay_port, "rogue": self.rogue_port}[route]
                    reader, writer = await asyncio.open_connection("127.0.0.1", port, **options)
                peer = writer.get_extra_info("ssl_object").getpeercert(binary_form=True)
                if hashlib.sha256(peer).hexdigest() != (expected_pin or self.server_pin):
                    raise ssl.SSLError("wrong server identity")
                connection = Connection(route, reader, writer, {}, 0)
                connection.ready = await connection.request("attach")
                if connection.ready["session"] != self.session:
                    raise ConnectionError("wrong session")
                connection.elapsed_ms = (time.perf_counter() - started) * 1000
                return connection
        except BaseException:
            if writer:
                writer.close()
            raise

    async def close(self):
        for listener in self.listeners:
            listener.close()
        for writer in list(self.active):
            writer.close()
        tasks = list(self.handlers)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        try:
            for listener in self.listeners:
                await asyncio.wait_for(listener.wait_closed(), 2)
        finally:
            if self.shell is not None and self.shell.returncode is None:
                self.shell.stdin.close()
                try:
                    await asyncio.wait_for(self.shell.wait(), 2)
                except TimeoutError:
                    self.shell.kill()
                    await self.shell.wait()


class Selector:
    def __init__(self, fixture):
        self.fixture = fixture
        self.cache = {}

    async def select(self, network, mode="automatic", direct=True, relay=True, local=True, refresh=False):
        permitted = (["local"] if local and mode != "relay" else [])
        permitted += ["direct"] if direct and mode != "relay" else []
        permitted += ["relay"] if relay and mode != "direct" else []
        key = (network, mode)
        cached = self.cache.get(key)
        if cached in permitted and not refresh:
            try:
                return await self.fixture.connect(cached)
            except (OSError, TimeoutError, ConnectionError):
                permitted.remove(cached)
        tasks = [asyncio.create_task(self.fixture.connect(route)) for route in permitted]
        winner = None
        try:
            for result in asyncio.as_completed(tasks):
                try:
                    winner = await result
                    self.cache[key] = winner.route
                    return winner
                except (OSError, TimeoutError, ConnectionError):
                    continue
            self.cache.pop(key, None)
            raise ConnectionError("no permitted authenticated route is ready")
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            for result in results:
                if isinstance(result, Connection) and result is not winner:
                    await result.close()


async def run(output):
    output.unlink(missing_ok=True)
    checks = []
    completed = False
    cleanup_error = None
    def check(name, condition, **evidence):
        checks.append({"name": name, "passed": bool(condition), **evidence})
        if not condition:
            raise AssertionError(name)
    with tempfile.TemporaryDirectory(prefix="myterm-routing-") as temp:
        fixture = Fixture(Path(temp))
        try:
            await fixture.start()
            selector = Selector(fixture)
            connection = await selector.select("wifi-a")
            check("first authenticated attach-ready route wins", connection.route == "local", elapsed_ms=connection.elapsed_ms)
            original = connection.ready
            response = await connection.request("write", text="before-route-change")
            check("fixture shell increments counter before route change", response["output"] == f"{original['pid']}:1:before-route-change")
            await connection.close()
            fixture.delays["local"] = 0.2
            before = dict(fixture.attempts)
            connection = await selector.select("wifi-a")
            check("remembered route does not race alternatives", connection.route == "local" and fixture.attempts["relay"] == before["relay"] and fixture.attempts["direct"] == before["direct"])
            await connection.close()
            connection = await selector.select("wifi-a", refresh=True)
            check("Settings refresh reraces permitted routes", connection.route == "direct", elapsed_ms=connection.elapsed_ms)
            await connection.close()
            connection = await selector.select("vpn-a")
            check("network context has its own route choice", connection.route == "direct")
            before = dict(fixture.attempts)
            await connection.request("attach")
            check("RPC on retained socket starts no route attempts", before == fixture.attempts)
            # Break the selected transport while leaving the server-owned shell alive.
            connection.writer.transport.abort()
            for listener in fixture.listeners[1:2]:
                listener.close()
                await listener.wait_closed()
            fixture.delays["local"] = 0.01
            started = time.perf_counter()
            recovered = await selector.select("vpn-a")
            response = await recovered.request("write", text="after-route-change")
            check("fixture shell PID and counter survive socket replacement", recovered.ready == original and response["output"] == f"{original['pid']}:2:after-route-change", elapsed_ms=(time.perf_counter()-started)*1000, pid=original["pid"])
            await recovered.close()
            await connection.close()
            before = fixture.attempts["relay"]
            try:
                await selector.select("failed-direct", mode="direct", local=False)
                blocked = False
            except ConnectionError:
                blocked = True
            check("failed Direct only never attempts relay", blocked and fixture.attempts["relay"] == before)
            replacement = await asyncio.start_server(
                lambda r, w: fixture.serve(r, w, "direct"), "127.0.0.1", 0,
                ssl=fixture.server_context)
            fixture.listeners.append(replacement)
            fixture.direct_port = replacement.sockets[0].getsockname()[1]
            before = fixture.attempts["relay"]
            connection = await selector.select("direct-mode", mode="direct", relay=False)
            check("Direct only permits same-machine local and no relay", connection.route == "local" and fixture.attempts["relay"] == before)
            await connection.close()
            before = {name: fixture.attempts[name] for name in ("local", "direct")}
            connection = await selector.select("relay-mode", mode="relay")
            check("Relay only excludes local and direct candidates", connection.route == "relay" and all(fixture.attempts[name] == count for name, count in before.items()), elapsed_ms=connection.elapsed_ms)
            check("relay transport reaches same server identity and shell", connection.ready == original)
            await connection.close()
            before = dict(fixture.attempts)
            try:
                await selector.select("disabled", mode="relay", relay=False)
                blocked = False
            except ConnectionError:
                blocked = True
            check("disabled relay cannot silently fall back", blocked and before == fixture.attempts)
            try:
                await fixture.connect("rogue")
                rejected = False
            except ssl.SSLCertVerificationError:
                rejected = True
            check("untrusted server certificate rejected before attach", rejected)
            try:
                await fixture.connect("direct", expected_pin="0"*64)
                rejected = False
            except ssl.SSLError as error:
                rejected = "wrong server identity" in str(error)
            check("trusted certificate with wrong identity pin rejected", rejected)
            for client in ("rogue-client", "missing-client"):
                try:
                    await fixture.connect("direct", client=client)
                    rejected = False
                except (ssl.SSLError, ConnectionError):
                    rejected = True
                check(f"{client} rejected before attach-ready response", rejected)
            saved_port = fixture.direct_port
            fixture.direct_port = fixture.rogue_port
            attempts_before = fixture.attempts["direct"]
            try:
                connection = await selector.select("untrusted-race")
                check("fast untrusted candidate attempted but cannot win route race", connection.route == "local" and fixture.attempts["direct"] == attempts_before + 1)
                await connection.close()
            finally:
                fixture.direct_port = saved_port
            viewer = await fixture.connect("relay", "client-b")
            reply = await viewer.request("write", text="forbidden")
            check("fixture viewer input rejected through relay", reply == {"error": "viewer", "controller": "client-a"} and viewer.ready["pid"] == original["pid"])
            await viewer.close()
            fixture.delays["local"] = 2
            started = time.perf_counter()
            try:
                await fixture.connect("local", timeout=0.08)
                expired = False
            except TimeoutError:
                expired = True
            elapsed = (time.perf_counter()-started)*1000
            check("route deadline includes application attach readiness", expired and elapsed < 500, elapsed_ms=elapsed, configured_ms=80)
            check("fixture owns the original live shell at completion", fixture.shell.returncode is None)
            async with asyncio.timeout(3):
                while fixture.active or fixture.handlers:
                    await asyncio.sleep(0.01)
            check("server-side race losers and timed-out handlers eventually close", not fixture.active and not fixture.handlers)
            completed = True
        finally:
            try:
                await fixture.close()
            except Exception as error:
                cleanup_error = error
                completed = False
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps({
                "recorded_at": datetime.now(timezone.utc).isoformat(),
                "completed": completed,
                "cleanup_error": type(cleanup_error).__name__ if cleanup_error else None,
                "environment": {"system": platform.system(), "machine": platform.machine(), "python": platform.python_version(), "tls": ssl.OPENSSL_VERSION},
                "scope": "Loopback Python TLS 1.3 sockets, Unix socket, opaque TCP forwarding fixture and real shell with pipes; no PTY, SwiftTerm, native application, hosted relay, real network change, enrollment or Azure validation.",
                "checks": checks,
            }, indent=2) + "\n")
    if cleanup_error:
        raise RuntimeError("fixture cleanup failed; see evidence") from cleanup_error
    print(f"{sum(c['passed'] for c in checks)}/{len(checks)} checks passed; {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    asyncio.run(run(parser.parse_args().output))
