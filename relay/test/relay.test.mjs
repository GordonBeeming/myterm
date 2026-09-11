// Integration tests for the MyTerm relay.
//
// Starts `wrangler dev` (local mode) as a child process against the real
// Worker + Durable Object code, then drives the protocol over real
// WebSocket connections using Node's built-in WebSocket and http clients.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const relayDir = path.resolve(__dirname, "..");

const PORT = 8799;
const BASE_HTTP = `http://127.0.0.1:${PORT}`;
const BASE_WS = `ws://127.0.0.1:${PORT}`;

let wranglerProcess;

function randomId(prefix) {
  return `${prefix}${crypto.randomUUID().replace(/-/g, "")}`.slice(0, 32);
}

async function waitForServer(timeoutMs) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${BASE_HTTP}/`);
      if (res.status === 200) {
        const text = await res.text();
        if (text === "myterm relay") return;
      }
    } catch (err) {
      lastError = err;
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`relay did not come up in time: ${lastError}`);
}

/** Waits for a WebSocket to reach OPEN, or rejects on error/unexpected close. */
function waitOpen(ws) {
  return new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve(), { once: true });
    ws.addEventListener("error", (e) => reject(new Error(`ws error: ${e.message ?? e}`)), {
      once: true,
    });
  });
}

/** Waits for a single close event, resolving with { code, reason }. */
function waitClose(ws) {
  return new Promise((resolve) => {
    ws.addEventListener(
      "close",
      (e) => resolve({ code: e.code, reason: e.reason }),
      { once: true },
    );
  });
}

/**
 * Collects every message a socket receives, from the moment this is called, so a test can read
 * them in order without racing the relay: a WebSocket keeps nothing for a listener attached late.
 * Text frames are parsed as JSON; binary frames become Uint8Arrays. Blob reads are chained, so a
 * slow one can never overtake the next.
 */
function inbox(ws) {
  const queue = [];
  const waiters = [];
  let chain = Promise.resolve();
  ws.addEventListener("message", (e) => {
    chain = chain.then(async () => {
      let value;
      if (typeof e.data === "string") value = JSON.parse(e.data);
      else if (e.data instanceof Blob) value = new Uint8Array(await e.data.arrayBuffer());
      else value = new Uint8Array(e.data);
      if (waiters.length) waiters.shift()(value);
      else queue.push(value);
    });
  });
  return {
    next: () => (queue.length ? Promise.resolve(queue.shift()) : new Promise((r) => waiters.push(r))),
  };
}

before(async () => {
  wranglerProcess = spawn(
    "npx",
    ["wrangler", "dev", "--port", String(PORT), "--local", "--log-level", "warn"],
    {
      cwd: relayDir,
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env, CI: "true" },
    },
  );

  let stderrBuf = "";
  wranglerProcess.stderr.on("data", (chunk) => {
    stderrBuf += chunk.toString();
  });
  wranglerProcess.on("exit", (code, signal) => {
    if (code !== null && code !== 0) {
      console.error(`wrangler dev exited early (code=${code} signal=${signal}):\n${stderrBuf}`);
    }
  });

  await waitForServer(60_000);
});

after(async () => {
  if (!wranglerProcess) return;
  wranglerProcess.kill("SIGTERM");
  await new Promise((resolve) => {
    wranglerProcess.once("exit", resolve);
    setTimeout(resolve, 5_000);
  });
});

test("GET /v1/health reports ok", async () => {
  const res = await fetch(`${BASE_HTTP}/v1/health`);
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.deepEqual(body, { ok: true });
});

test("host registers, device connects, bytes flow both ways, close propagates", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();
  assert.equal(openMsg.type, "open");
  assert.equal(typeof openMsg.session, "string");
  assert.match(openMsg.session, /^[0-9a-f]{32}$/);

  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  // device -> host: sent as a Uint8Array view (what a real client sends), forwarded byte-for-byte.
  const deviceToHost = new TextEncoder().encode("hello from device");
  device.send(deviceToHost);
  const receivedByHost = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedByHost), Buffer.from(deviceToHost));

  // host -> device
  const hostToDevice = new TextEncoder().encode("hello from host");
  hostSession.send(hostToDevice);
  const receivedByDevice = await deviceInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedByDevice), Buffer.from(hostToDevice));

  // closing the device propagates a 1000 "peer closed" to the host session socket.
  const hostSideClose = waitClose(hostSession);
  device.close(1000, "done");
  const closeEvent = await hostSideClose;
  assert.equal(closeEvent.code, 1000);
  assert.equal(closeEvent.reason, "peer closed");

  host.close();
});

test("buffered device frames sent before the host answers are flushed in order", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();

  // Send frames before the host session socket exists; they must be buffered and flushed in order.
  device.send(new TextEncoder().encode("first"));
  device.send(new TextEncoder().encode("second"));

  // Give the relay a beat to buffer both frames before the host connects.
  await new Promise((r) => setTimeout(r, 200));

  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  const first = await sessionInbox.next();
  assert.equal(new TextDecoder().decode(first), "first");
  const second = await sessionInbox.next();
  assert.equal(new TextDecoder().decode(second), "second");

  device.close();
  host.close();
});

test("forwards arbitrary binary payloads byte-for-byte, as both a Uint8Array view and a plain ArrayBuffer", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);

  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(
    `${BASE_WS}/v1/host/${id}/session/${openMsg.session}`,
    { headers: { "X-MyTerm-Host-Key": key } },
  );
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  // Every byte value 0x00-0xff, sent as a Uint8Array view over a larger backing buffer (with a
  // non-zero byteOffset) — this is the exact shape that produced empty frames before the fix.
  const backing = new Uint8Array(8 + 256);
  for (let i = 0; i < 256; i++) backing[8 + i] = i;
  const allBytesView = new Uint8Array(backing.buffer, 8, 256);

  device.send(allBytesView);
  const receivedAllBytes = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedAllBytes), Buffer.from(allBytesView));

  // A batch of cryptographically random bytes, sent as a plain ArrayBuffer, device -> host.
  const randomPayload = new Uint8Array(4096);
  crypto.getRandomValues(randomPayload);
  device.send(randomPayload.buffer);
  const receivedRandom = await sessionInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedRandom), Buffer.from(randomPayload));

  // Same, host -> device, as a Uint8Array view.
  const replyPayload = new Uint8Array(4096);
  crypto.getRandomValues(replyPayload);
  hostSession.send(replyPayload);
  const receivedReply = await deviceInbox.next();
  assert.deepStrictEqual(Buffer.from(receivedReply), Buffer.from(replyPayload));

  device.close();
  host.close();
});

test("device gets 4004 when no host is connected for the id", async () => {
  const id = randomId("id-");
  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  const closeEvent = await waitClose(device);
  assert.equal(closeEvent.code, 4004);
  assert.equal(closeEvent.reason, "host offline");
});

test("host session socket with the wrong key is rejected with HTTP 403", async () => {
  const id = randomId("id-");
  const key = randomId("key-");
  const wrongKey = randomId("wrong-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);
  const openMsg = await hostInbox.next();

  const status = await attemptUpgradeAndGetStatus(
    `/v1/host/${id}/session/${openMsg.session}`,
    { "X-MyTerm-Host-Key": wrongKey },
  );
  assert.equal(status, 403);

  device.close();
  host.close();
});

test("a control socket with the wrong key is rejected with HTTP 403", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);

  const status = await attemptUpgradeAndGetStatus(`/v1/host/${id}`, {
    "X-MyTerm-Host-Key": randomId("wrong-"),
  });
  assert.equal(status, 403);

  // The first key still works: the wrong one did not overwrite it.
  const again = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(again);
  again.close();
  host.close();
});

test("a second Mac cannot take an id whose Mac is offline", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  host.close();
  await waitClose(host);

  // The Mac is gone; the id is still its own.
  const status = await attemptUpgradeAndGetStatus(`/v1/host/${id}`, {
    "X-MyTerm-Host-Key": randomId("other-"),
  });
  assert.equal(status, 403);
});

test("malformed requests are refused before they reach a Durable Object", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  // Ids and keys: 16-128 chars of [A-Za-z0-9_-].
  assert.equal(await attemptUpgradeAndGetStatus(`/v1/device/short`, {}), 400);
  assert.equal(await attemptUpgradeAndGetStatus(`/v1/device/${"x".repeat(129)}`, {}), 400);
  assert.equal(await attemptUpgradeAndGetStatus(`/v1/device/${id}%2F..`, {}), 400);
  assert.equal(await attemptUpgradeAndGetStatus(`/v1/host/${id}`, {}), 400);
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}`, { "X-MyTerm-Host-Key": "short" }),
    400,
  );
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}/session/${"s".repeat(129)}`, {
      "X-MyTerm-Host-Key": key,
    }),
    400,
  );

  // A plain GET on a socket endpoint is not upgraded.
  const plain = await fetch(`${BASE_HTTP}/v1/device/${id}`);
  assert.equal(plain.status, 426);
  const plainHost = await fetch(`${BASE_HTTP}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  assert.equal(plainHost.status, 426);

  // Nothing else exists, and a refusal says nothing about the Worker's insides.
  const missing = await fetch(`${BASE_HTTP}/v1/nope`);
  assert.equal(missing.status, 404);
  assert.equal(await missing.text(), "not found");
  const posted = await fetch(`${BASE_HTTP}/v1/health`, { method: "POST" });
  assert.equal(posted.status, 404);
});

test("a host session socket for an unknown or already-joined session gets 404", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  // No such session.
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}/session/${"0".repeat(32)}`, {
      "X-MyTerm-Host-Key": key,
    }),
    404,
  );

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${openMsg.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);

  // Joined: a second socket for the same session cannot take it over.
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}/session/${openMsg.session}`, {
      "X-MyTerm-Host-Key": key,
    }),
    404,
  );

  hostSession.close();
  device.close();
  host.close();
});

test("the Mac going away closes a pending device with 4004", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  await hostInbox.next();
  device.send(new TextEncoder().encode("still waiting"));

  const deviceClosed = waitClose(device);
  host.close();
  const closeEvent = await deviceClosed;
  assert.equal(closeEvent.code, 4004);
  assert.equal(closeEvent.reason, "host offline");
});

test("the Mac closing a session mid-stream closes the device with 1000, and the relay carries on", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${openMsg.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  // A burst from the device, with the Mac hanging up in the middle of it.
  const chunk = new Uint8Array(16 * 1024);
  crypto.getRandomValues(chunk);
  device.send(chunk);
  const firstAtHost = await sessionInbox.next();
  assert.equal(firstAtHost.byteLength, chunk.byteLength);
  const deviceClosed = waitClose(device);
  for (let i = 0; i < 8; i++) device.send(chunk);
  hostSession.close(1000, "bye");
  const closeEvent = await deviceClosed;
  assert.equal(closeEvent.code, 1000);
  assert.equal(closeEvent.reason, "peer closed");

  // The same Mac and a new device pair up again straight away.
  const device2 = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device2);
  const device2Inbox = inbox(device2);
  const open2 = await hostInbox.next();
  assert.notEqual(open2.session, openMsg.session);
  const hostSession2 = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${open2.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession2);
  hostSession2.send(new TextEncoder().encode("again"));
  assert.equal(new TextDecoder().decode(await device2Inbox.next()), "again");

  hostSession2.close();
  device2.close();
  host.close();
});

test("a Mac reconnecting takes its id back: the old control socket sees 4001 and new devices reach the new one", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const first = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(first);
  const firstInbox = inbox(first);
  const firstClosed = waitClose(first);

  const second = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(second);
  const secondInbox = inbox(second);

  const replaced = await firstClosed;
  assert.equal(replaced.code, 4001);
  assert.equal(replaced.reason, "replaced");

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);
  const openMsg = await secondInbox.next();
  assert.equal(openMsg.type, "open");

  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${openMsg.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);
  hostSession.send(new TextEncoder().encode("new mac"));
  assert.equal(new TextDecoder().decode(await deviceInbox.next()), "new mac");

  // The replaced socket was told nothing about the device.
  let leaked = false;
  firstInbox.next().then(() => { leaked = true; });
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(leaked, false);

  hostSession.close();
  device.close();
  second.close();
});

test("text frames on a session socket are dropped, never forwarded into the stream", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);
  device.send("not bytes, before the host answers");
  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${openMsg.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);

  device.send("not bytes, after the host answered");
  device.send(new TextEncoder().encode("bytes"));
  assert.equal(new TextDecoder().decode(await sessionInbox.next()), "bytes");

  hostSession.send('{"type":"ping"}');
  hostSession.send(new TextEncoder().encode("reply"));
  assert.equal(new TextDecoder().decode(await deviceInbox.next()), "reply");

  hostSession.close();
  device.close();
  host.close();
});

test("a device that sends more than 64 KiB before the Mac answers is closed with 1009 and its session is gone", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const openMsg = await hostInbox.next();

  const deviceClosed = waitClose(device);
  const chunk = new Uint8Array(8 * 1024);
  for (let i = 0; i < 9; i++) device.send(chunk); // 72 KiB, past the 64 KiB cap
  const closeEvent = await deviceClosed;
  assert.equal(closeEvent.code, 1009);
  assert.equal(closeEvent.reason, "buffer overflow");

  // The session must not linger for the Mac to join later.
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}/session/${openMsg.session}`, {
      "X-MyTerm-Host-Key": key,
    }),
    404,
  );
  host.close();
});

test("a frame over 1 MiB closes the socket that sent it with 1009, and the peer with 1000", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const openMsg = await hostInbox.next();
  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${openMsg.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);

  const deviceClosed = waitClose(device);
  const hostSessionClosed = waitClose(hostSession);
  device.send(new Uint8Array(1024 * 1024 + 1));
  assert.equal((await deviceClosed).code, 1009);
  assert.equal((await hostSessionClosed).code, 1000);
  host.close();
});

test("the seventeenth pending session for an id is refused with 4029", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const devices = [];
  for (let i = 0; i < 16; i++) {
    const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
    await waitOpen(device);
    devices.push(device);
    assert.equal((await hostInbox.next()).type, "open");
  }

  const extra = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  const closeEvent = await waitClose(extra);
  assert.equal(closeEvent.code, 4029);
  assert.equal(closeEvent.reason, "too many sessions");

  // Closing one frees a slot.
  const freed = waitClose(devices[0]);
  devices[0].close();
  await freed;
  const next = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(next);
  assert.equal((await hostInbox.next()).type, "open");

  next.close();
  for (const device of devices.slice(1)) device.close();
  host.close();
});

test("a Mac that never opens the session leaves the device with 4008 after ten seconds", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  const host = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(host);
  const hostInbox = inbox(host);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const openMsg = await hostInbox.next();
  const started = Date.now();
  const closeEvent = await waitClose(device);
  assert.equal(closeEvent.code, 4008);
  assert.equal(closeEvent.reason, "host did not answer");
  assert.ok(Date.now() - started >= 9_000, "the Mac gets its ten seconds");

  // Too late: the session is gone.
  assert.equal(
    await attemptUpgradeAndGetStatus(`/v1/host/${id}/session/${openMsg.session}`, {
      "X-MyTerm-Host-Key": key,
    }),
    404,
  );
  host.close();
});

test("a device that arrived while the Mac was reconnecting is handed to the new control socket", async () => {
  const id = randomId("id-");
  const key = randomId("key-");

  // The old socket: from the relay's side still open, from the Mac's side already dead.
  const stale = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(stale);
  const staleInbox = inbox(stale);

  const device = new WebSocket(`${BASE_WS}/v1/device/${id}`);
  await waitOpen(device);
  const deviceInbox = inbox(device);
  const announcedToStale = await staleInbox.next();
  device.send(new TextEncoder().encode("sent while the Mac was away"));

  const fresh = new WebSocket(`${BASE_WS}/v1/host/${id}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(fresh);
  const freshInbox = inbox(fresh);
  const announcedAgain = await freshInbox.next();
  assert.equal(announcedAgain.type, "open");
  assert.equal(announcedAgain.session, announcedToStale.session);

  const hostSession = new WebSocket(`${BASE_WS}/v1/host/${id}/session/${announcedAgain.session}`, {
    headers: { "X-MyTerm-Host-Key": key },
  });
  await waitOpen(hostSession);
  const sessionInbox = inbox(hostSession);
  assert.equal(new TextDecoder().decode(await sessionInbox.next()), "sent while the Mac was away");
  hostSession.send(new TextEncoder().encode("back"));
  assert.equal(new TextDecoder().decode(await deviceInbox.next()), "back");

  hostSession.close();
  device.close();
  fresh.close();
});

/**
 * Performs a raw HTTP WebSocket-upgrade handshake and resolves with the status
 * code the server responded with. Node's global WebSocket does not expose the
 * rejecting HTTP status directly, so this uses node:http instead.
 */
function attemptUpgradeAndGetStatus(pathname, extraHeaders) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: "127.0.0.1",
      port: PORT,
      path: pathname,
      method: "GET",
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": Buffer.from(crypto.randomUUID()).toString("base64").slice(0, 24),
        ...extraHeaders,
      },
    });

    req.on("response", (res) => {
      res.resume();
      resolve(res.statusCode);
    });
    req.on("upgrade", (res) => {
      resolve(res.statusCode);
    });
    req.on("error", reject);
    req.end();
  });
}
