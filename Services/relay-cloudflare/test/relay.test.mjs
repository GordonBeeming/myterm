import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { readFile, readdir } from "node:fs/promises";
import { action, connect, Endpoint, newAnchor, nextWebSocketEvent } from "./endpoint-fixture.mjs";
import { VirtualAuthenticator } from "./virtual-authenticator.mjs";
import { after, test } from "node:test";
import { convertV4MiniflareOptions, Miniflare } from "miniflare";

const origin = "https://myterm-relay-beta.gordonbeeming.dev";
const bindings = {
  RELAY_CHANNEL: "beta",
  RELAY_ORIGIN: origin,
  RELAY_RP_ID: "myterm-relay-beta.gordonbeeming.dev",
  RELAY_REGISTRATION: "public",
  RELAY_REVISION: "0123456789012345678901234567890123456789",
  RELAY_OPERATOR_BOOTSTRAP: "fixture-only",
};

const fixtures = [];
after(async () => Promise.all(fixtures.map((fixture) => fixture.dispose())));

function fixture(overrides = {}) {
  const instance = new Miniflare(convertV4MiniflareOptions({
    modules: true,
    scriptPath: "dist/index.js",
    compatibilityDate: "2026-11-27",
    compatibilityFlags: ["nodejs_compat"],
    d1Databases: { ACCOUNT_DB: "relay-test-db" },
    r2Buckets: { SECURITY_CONTROL: "relay-test-control" },
    durableObjects: { ACCOUNT_ROUTER: { className: "AccountRouter", useSQLite: true } },
    bindings: { ...bindings, ...overrides },
  }));
  fixtures.push(instance);
  return instance;
}

test("preflight reports the version and rejects crossed beta origins and passkey RP IDs", async () => {
  const relay = fixture();
  const supported = await relay.dispatchFetch(origin + "/v1/capabilities");
  assert.equal(supported.status, 200);
  assert.equal((await supported.json()).protocol, 1);
  const crossed = await relay.dispatchFetch("https://myterm-relay.gordonbeeming.dev/v1/capabilities");
  assert.equal(crossed.status, 421);
  const unsafe = await fixture({ RELAY_RP_ID: "gordonbeeming.dev" }).dispatchFetch(origin + "/v1/capabilities");
  assert.equal(unsafe.status, 503);
  const privateDevelopment = await fixture({
    RELAY_ORIGIN: "https://myterm-relay-dev.gordonbeeming.dev",
    RELAY_RP_ID: "myterm-relay-dev.gordonbeeming.dev",
  }).dispatchFetch("https://myterm-relay-dev.gordonbeeming.dev/v1/capabilities");
  assert.equal(privateDevelopment.status, 503);
});

async function migrate(relay) {
  const db = await relay.getD1Database("ACCOUNT_DB");
  for (const migration of (await readdir("migrations")).sort()) {
    const sql = await readFile("migrations/" + migration, "utf8");
    await db.batch(sql.split(";").map((statement) => statement.trim()).filter(Boolean).map((statement) => db.prepare(statement)));
  }
}

const post = (relay, route, body, extraHeaders = {}) => relay.dispatchFetch(origin + route, {
  method: "POST",
  headers: { "content-type": "application/json", ...extraHeaders },
  body: JSON.stringify(body),
});

test("passkey registration and sign-in require verified exact-origin WebAuthn responses", async () => {
  const relay = fixture();
  await migrate(relay);
  const authenticator = new VirtualAuthenticator();
  const options = await post(relay, "/v1/passkeys/register/options", {});
  assert.equal(options.status, 200);
  const { publicKey } = await options.json();
  assert.equal(publicKey.authenticatorSelection.userVerification, "required");
  const body = { challenge: publicKey.challenge, credential: authenticator.register(publicKey, origin) };
  const registration = await post(relay, "/v1/passkeys/register/finish", body);
  assert.equal(registration.status, 201);
  const registered = await registration.json();
  assert.equal(typeof registered.accountId, "string");
  assert.equal(typeof registered.session, "string");
  assert.equal((await post(relay, "/v1/passkeys/register/finish", body)).status, 401);

  const login = await post(relay, "/v1/passkeys/login/options", {});
  const loginOptions = (await login.json()).publicKey;
  const signed = authenticator.authenticate(loginOptions, origin);
  const loginBody = { challenge: loginOptions.challenge, credential: signed };
  const verified = await post(relay, "/v1/passkeys/login/finish", loginBody);
  assert.equal(verified.status, 200);
  assert.equal((await verified.json()).accountId, registered.accountId);
  assert.equal((await post(relay, "/v1/passkeys/login/finish", loginBody)).status, 401);

  const wrong = await post(relay, "/v1/passkeys/login/options", {});
  const wrongOptions = (await wrong.json()).publicKey;
  assert.equal((await post(relay, "/v1/passkeys/login/finish", {
    challenge: wrongOptions.challenge,
    credential: authenticator.authenticate(wrongOptions, "https://attacker.example"),
  })).status, 401);
});

test("authenticated operator bootstrap issues a single-use invitation without granting endpoint trust", async () => {
  const relay = fixture({
    RELAY_CHANNEL: "self-hosted",
    RELAY_ORIGIN: "https://relay.example",
    RELAY_RP_ID: "relay.example",
    RELAY_REGISTRATION: "invitation",
    RELAY_OPERATOR_BOOTSTRAP: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
  });
  await migrate(relay);
  const selfOrigin = "https://relay.example";
  const request = (route, body, secret) => relay.dispatchFetch(selfOrigin + route, {
    method: "POST",
    headers: { "content-type": "application/json", ...(secret ? { authorization: "Bearer " + secret } : {}) },
    body: JSON.stringify(body),
  });
  assert.equal((await request("/v1/passkeys/register/options", {})).status, 403);
  assert.equal((await request("/v1/operator/bootstrap/options", {})).status, 401);
  const bootstrap = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  const options = (await (await request("/v1/operator/bootstrap/options", {}, bootstrap)).json()).publicKey;
  const operator = await request("/v1/operator/bootstrap/finish", {
    challenge: options.challenge,
    credential: new VirtualAuthenticator().register(options, selfOrigin),
  }, bootstrap);
  assert.equal(operator.status, 201);
  assert.equal((await request("/v1/operator/bootstrap/options", {}, bootstrap)).status, 409);

  const invitation = await request("/v1/operator/invitations", { lifetimeSeconds: 600 }, (await operator.json()).session);
  assert.equal(invitation.status, 201);
  const { token } = await invitation.json();
  const optionsResponses = await Promise.all([0, 1].map(() =>
    request("/v1/passkeys/register/options", { invitation: token }),
  ));
  const requests = await Promise.all(optionsResponses.map(async response => {
    assert.equal(response.status, 200);
    return (await response.json()).publicKey;
  }));
  const invites = await Promise.all(requests.map(options => {
    return request("/v1/passkeys/register/finish", {
      challenge: options.challenge,
      credential: new VirtualAuthenticator().register(options, selfOrigin),
    });
  }));
  assert.deepEqual(invites.map(({ status }) => status).sort(), [201, 403]);
  assert.equal((await request("/v1/passkeys/register/options", { invitation: token })).status, 403);
});

async function registerUser(relay, bootstrap) {
  const mode = bootstrap ? "/v1/operator/bootstrap" : "/v1/passkeys/register";
  const headers = bootstrap ? { Authorization: "Bearer " + bootstrap } : {};
  const { publicKey } = await (await post(relay, mode + "/options", {}, headers)).json();
  const response = await post(relay, mode + "/finish", {
    challenge: publicKey.challenge,
    credential: new VirtualAuthenticator().register(publicKey, origin),
  }, headers);
  assert.equal(response.status, 201);
  return response.json();
}

test("approved peers exchange opaque binary frames and operator suspension fences existing sockets", async () => {
  const bootstrap = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA";
  const relay = fixture({ RELAY_OPERATOR_BOOTSTRAP: bootstrap });
  await migrate(relay);
  const { accountId, session } = await registerUser(relay);
  const other = await registerUser(relay);
  const operator = await registerUser(relay, bootstrap);
  const client = new Endpoint();
  const server = new Endpoint();
  const anchor = newAnchor();
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, other.session)).status, 403);
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, operator.session)).status, 403);
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, session)).status, 201);
  assert.equal((await action(relay, origin, accountId, anchor, server, "connect")).status, 401);
  assert.equal((await action(relay, origin, accountId, anchor, client, "admit", {
    targetEndpointId: server.id, signingKey: server.publicKey, kind: "server", relayEnabled: true,
  })).status, 201);
  assert.equal((await action(relay, origin, other.accountId, anchor, client, "connect")).status, 401);

  const fromClient = await connect(relay, origin, accountId, anchor, client);
  const fromServer = await connect(relay, origin, accountId, anchor, server);
  const ciphertext = Buffer.from([0xcd, 0x01, 0xaf, 0x00]);
  const arriving = nextWebSocketEvent(fromServer, "message");
  fromClient.send(Buffer.concat([Buffer.from(server.id, "hex"), ciphertext]));
  const received = Buffer.from((await arriving).data);
  assert.equal(received.subarray(0, 32).toString("hex"), client.id);
  assert.deepEqual(received.subarray(48), ciphertext);
  const returning = nextWebSocketEvent(fromClient, "message");
  fromServer.send(Buffer.concat([Buffer.from(client.id, "hex"), ciphertext]));
  assert.deepEqual(Buffer.from((await returning).data).subarray(48), ciphertext);

  const clientClosed = nextWebSocketEvent(fromClient, "close");
  const serverClosed = nextWebSocketEvent(fromServer, "close");
  const suspend = await post(relay, "/v1/accounts/" + accountId + "/suspension", { suspended: true }, {
    Authorization: "Bearer " + operator.session,
  });
  assert.equal(suspend.status, 200);
  assert.equal((await clientClosed).code, 4403);
  assert.equal((await serverClosed).code, 4403);
  assert.equal((await action(relay, origin, accountId, anchor, client, "connect")).status, 401);
});

test("native passkey sign-in returns a code bound to its S256 verifier and exact callback", async () => {
  const relay = fixture();
  await migrate(relay);
  const authenticator = new VirtualAuthenticator();
  const redirectUri = "myterm-companion://auth/callback";
  const verifier = Buffer.alloc(32, 7).toString("base64url");
  const state = Buffer.alloc(32, 8).toString("base64url");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  const codeChallenge = Buffer.from(digest).toString("base64url");
  const query = new URLSearchParams({
    redirect_uri: redirectUri, state, code_challenge: codeChallenge, code_challenge_method: "S256",
  });
  const page = await relay.dispatchFetch(origin + "/auth/register?" + query);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /text\/html/);
  assert.equal(page.headers.get("cache-control"), "no-store");
  query.set("redirect_uri", "myterm-companion://auth/callback?other=value");
  assert.equal((await relay.dispatchFetch(origin + "/auth/register?" + query)).status, 400);

  const authorization = { redirectUri, codeChallenge };
  const accepted = await post(relay, "/v1/passkeys/register/options", { authorization });
  assert.equal(accepted.status, 200);
  const options = (await accepted.json()).publicKey;
  const finish = await post(relay, "/v1/passkeys/register/finish", {
    challenge: options.challenge,
    credential: authenticator.register(options, origin),
  });
  assert.equal(finish.status, 201);
  const { code, session } = await finish.json();
  assert.equal(typeof code, "string");
  assert.equal(session, undefined);

  const exchange = (payload) => post(relay, "/v1/passkeys/session", payload);
  assert.equal((await exchange({ code, codeVerifier: "A".repeat(43), redirectUri })).status, 401);
  assert.equal((await exchange({ code, codeVerifier: verifier, redirectUri: "myterm://companion-auth/callback" })).status, 401);
  const payload = { code, codeVerifier: verifier, redirectUri };
  const concurrent = await Promise.all([exchange(payload), exchange(payload)]);
  assert.deepEqual(concurrent.map(({ status }) => status).sort(), [200, 401]);
  const exchanged = await concurrent.find(({ status }) => status === 200).json();
  assert.equal(typeof exchanged.accountId, "string");
  assert.equal(typeof exchanged.session, "string");
  assert.ok(exchanged.expiresAt > Date.now());

  const login = await post(relay, "/v1/passkeys/login/options", { authorization });
  assert.equal(login.status, 200);
  const loginOptions = (await login.json()).publicKey;
  const nativeSignIn = await post(relay, "/v1/passkeys/login/finish", {
    challenge: loginOptions.challenge,
    credential: authenticator.authenticate(loginOptions, origin),
  });
  assert.equal(nativeSignIn.status, 200);
  const loginCode = await nativeSignIn.json();
  assert.equal(loginCode.session, undefined);
  const loggedIn = await exchange({ ...payload, code: loginCode.code });
  assert.equal(loggedIn.status, 200);
  assert.equal((await loggedIn.json()).accountId, exchanged.accountId);
});


test("one MyTerm server routes authenticated ciphertext independently to two approved clients", async () => {
  const relay = fixture();
  await migrate(relay);
  const { accountId, session } = await registerUser(relay);
  const owner = new Endpoint();
  const server = new Endpoint();
  const iphone = new Endpoint();
  const ipad = new Endpoint();
  const anchor = newAnchor();
  assert.equal((await action(relay, origin, accountId, anchor, owner, "genesis", {
    anchor, signingKey: owner.publicKey,
  }, session)).status, 201);

  const fixtures = [[server, "server"], [iphone, "client"], [ipad, "client"]];
  for (const [candidate, kind] of fixtures) {
    assert.equal((await action(relay, origin, accountId, anchor, owner, "admit", {
      targetEndpointId: candidate.id, signingKey: candidate.publicKey, kind, relayEnabled: true,
    })).status, 201);
  }
  const [serverSocket, phoneSocket, tabletSocket] = await Promise.all(fixtures.map(([endpoint]) =>
    connect(relay, origin, accountId, anchor, endpoint),
  ));
  const phoneKey = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const tabletKey = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const sockets = [
    { endpoint: iphone, socket: phoneSocket, key: phoneKey, alternateKey: tabletKey, label: "iPhone" },
    { endpoint: ipad, socket: tabletSocket, key: tabletKey, alternateKey: phoneKey, label: "iPad" },
  ];
  for (const client of sockets) {
    await exchangeEncrypted(client.socket, serverSocket, client.endpoint.id, server.id, client.key, client.alternateKey,
      "input from " + client.label);
    await exchangeEncrypted(serverSocket, client.socket, server.id, client.endpoint.id, client.key, client.alternateKey,
      "output for " + client.label);
  }

  const denied = nextWebSocketEvent(phoneSocket, "message");
  phoneSocket.send(Buffer.concat([Buffer.from(ipad.id, "hex"), randomBytes(16)]));
  assert.deepEqual(JSON.parse((await denied).data), { unavailable: ipad.id });

  const unapproved = new Endpoint();
  assert.equal((await action(relay, origin, accountId, anchor, iphone, "admit", {
    targetEndpointId: unapproved.id, signingKey: unapproved.publicKey, kind: "client", relayEnabled: true,
  })).status, 403);
  assert.equal((await action(relay, origin, accountId, anchor, iphone, "revoke", {
    targetEndpointId: ipad.id,
  })).status, 403);

  const reserved = await action(relay, origin, accountId, anchor, iphone, "connect", {});
  assert.equal(reserved.status, 200);
  const { ticket } = await reserved.json();
  const closed = nextWebSocketEvent(phoneSocket, "close");
  for (let attempt = 0; attempt < 2; attempt++) {
    assert.equal((await action(relay, origin, accountId, anchor, owner, "revoke", {
      targetEndpointId: iphone.id,
    })).status, 200);
  }
  assert.equal((await closed).code, 4403);
  assert.equal((await relay.dispatchFetch(`${origin}/v1/accounts/${accountId}/socket`, {
    headers: { upgrade: "websocket", authorization: "Bearer " + ticket },
  })).status, 401);
  assert.equal((await post(relay, `/v1/accounts/${accountId}/endpoint-challenge`, {
    endpointId: iphone.id, purpose: "connect",
  })).status, 401);
  assert.equal((await action(relay, origin, accountId, anchor, owner, "admit", {
    targetEndpointId: iphone.id, signingKey: iphone.publicKey, kind: "client", relayEnabled: true,
  })).status, 409);
  await exchangeEncrypted(tabletSocket, serverSocket, ipad.id, server.id, tabletKey, phoneKey, "iPad remains paired");
  for (const socket of [serverSocket, tabletSocket]) socket.close();
});

async function exchangeEncrypted(source, recipient, sourceId, destinationId, key, alternateKey, message) {
  const iv = randomBytes(12);
  const additionalData = Buffer.from(sourceId + destinationId, "hex");
  const params = { name: "AES-GCM", iv, additionalData };
  const ciphertext = Buffer.from(await crypto.subtle.encrypt(params, key, Buffer.from(message)));
  const arrival = nextWebSocketEvent(recipient, "message");
  source.send(Buffer.concat([Buffer.from(destinationId, "hex"), iv, ciphertext]));
  const frame = Buffer.from((await arrival).data);
  assert.equal(frame.subarray(0, 32).toString("hex"), sourceId);
  assert.deepEqual(frame.subarray(48), Buffer.concat([iv, ciphertext]));
  assert.equal(Buffer.from(await crypto.subtle.decrypt(params, key, frame.subarray(60))).toString(), message);
  await assert.rejects(crypto.subtle.decrypt(params, alternateKey, frame.subarray(60)));
  recipient.send(JSON.stringify({ ack: frame.subarray(32, 48).toString("base64url") }));
}

test("a late older socket and a duplicate proof do not evict the active endpoint", async () => {
  const relay = fixture();
  await migrate(relay);
  const { accountId, session } = await registerUser(relay);
  const client = new Endpoint(), server = new Endpoint(), anchor = newAnchor();
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, session)).status, 201);
  assert.equal((await action(relay, origin, accountId, anchor, client, "admit", {
    targetEndpointId: server.id, signingKey: server.publicKey, kind: "server", relayEnabled: true,
  })).status, 201);

  async function openClient() {
    const reservation = await action(relay, origin, accountId, anchor, client, "connect");
    assert.equal(reservation.status, 200);
    const { ticket } = await reservation.json();
    const response = await relay.dispatchFetch(`${origin}/v1/accounts/${accountId}/socket`, {
      headers: { upgrade: "websocket", authorization: "bEaReR " + ticket },
    });
    assert.equal(response.status, 101);
    const socket = response.webSocket;
    const challenge = nextWebSocketEvent(socket, "message");
    socket.accept();
    const { nonce } = JSON.parse((await challenge).data);
    return { socket, proof: JSON.stringify({ nonce, proof: client.signature(origin, anchor, "liveness", nonce) }) };
  }

  const older = await openClient(), newer = await openClient();
  const ready = nextWebSocketEvent(newer.socket, "message");
  newer.socket.send(newer.proof);
  assert.equal(JSON.parse((await ready).data).ready, true);
  newer.socket.send(newer.proof);
  const rejected = nextWebSocketEvent(older.socket, "close");
  older.socket.send(older.proof);
  assert.equal((await rejected).code, 4409);

  const host = await connect(relay, origin, accountId, anchor, server);
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  const other = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
  await exchangeEncrypted(host, newer.socket, server.id, client.id, key, other, "active route survives");
  host.close();
  newer.socket.close();
});

test("flow control defers a frame until the receiver can accept it without disconnecting", async () => {
  const relay = fixture();
  await migrate(relay);
  const { accountId, session } = await registerUser(relay);
  const client = new Endpoint(), server = new Endpoint(), anchor = newAnchor();
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, session)).status, 201);
  assert.equal((await action(relay, origin, accountId, anchor, client, "admit", {
    targetEndpointId: server.id, signingKey: server.publicKey, kind: "server", relayEnabled: true,
  })).status, 201);
  const source = await connect(relay, origin, accountId, anchor, server, true);
  const receiver = await connect(relay, origin, accountId, anchor, client, true);
  const payload = Buffer.concat([Buffer.from(client.id, "hex"), randomBytes(64 * 1024)]);
  const send = async () => {
    const reply = nextWebSocketEvent(source, "message");
    source.send(payload);
    return JSON.parse((await reply).data);
  };
  const receipts = [];
  for (let frame = 0; frame < 3; frame++) {
    const incoming = nextWebSocketEvent(receiver, "message");
    assert.deepEqual(await send(), { queued: client.id });
    receipts.push(Buffer.from((await incoming).data).subarray(32, 48).toString("base64url"));
  }
  assert.deepEqual(await send(), { deferred: client.id });
  const resumed = nextWebSocketEvent(receiver, "message");
  receiver.send(JSON.stringify({ ack: receipts.shift() }));
  let reply;
  for (let poll = 0; poll < 10; poll++) {
    reply = await send();
    if (reply.queued) break;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  assert.deepEqual(reply, { queued: client.id });
  assert.deepEqual(Buffer.from((await resumed).data).subarray(48), payload.subarray(32));
  source.close();
  receiver.close();
});

test("measurement: local quiet sockets, signed renewal and active round-trips", {
  skip: process.env.MYTERM_RELAY_MEASURE !== "1",
  timeout: 150_000,
}, async (test) => {
  const relay = fixture();
  await migrate(relay);
  const { accountId, session } = await registerUser(relay);
  const client = new Endpoint();
  const server = new Endpoint();
  const anchor = newAnchor();
  assert.equal((await action(relay, origin, accountId, anchor, client, "genesis", {
    anchor, signingKey: client.publicKey,
  }, session)).status, 201);
  assert.equal((await action(relay, origin, accountId, anchor, client, "admit", {
    targetEndpointId: server.id, signingKey: server.publicKey, kind: "server", relayEnabled: true,
  })).status, 201);
  const [clientSocket, serverSocket] = await Promise.all(
    [client, server].map((endpoint) => connect(relay, origin, accountId, anchor, endpoint)),
  );

  const quietStart = performance.now();
  const rounds = process.env.MYTERM_RELAY_MEASURE_LONG === "1" ? 4 : 1;
  for (let round = 0; round < rounds; round++) {
    await Promise.all([[client, clientSocket], [server, serverSocket]].map(async ([endpoint, socket]) => {
      const { data } = await nextWebSocketEvent(socket, "message", 40_000);
      const challenge = JSON.parse(data);
      assert.equal(challenge.challenge, "liveness");
      socket.send(JSON.stringify({
        nonce: challenge.nonce, proof: endpoint.signature(origin, anchor, "liveness", challenge.nonce),
      }));
    }));
  }
  const quietMilliseconds = performance.now() - quietStart;

  const ciphertext = randomBytes(512);
  const outgoing = Buffer.concat([Buffer.from(server.id, "hex"), ciphertext]);
  const incoming = Buffer.concat([Buffer.from(client.id, "hex"), ciphertext]);
  const measures = [];
  const activeStart = performance.now();
  for (let sequence = 0; sequence < 240; sequence++) {
    const start = performance.now();
    await measuredFrame(clientSocket, serverSocket, outgoing, ciphertext);
    await measuredFrame(serverSocket, clientSocket, incoming, ciphertext);
    measures.push(performance.now() - start);
  }
  const activeMilliseconds = performance.now() - activeStart;
  measures.sort((lhs, rhs) => lhs - rhs);
  test.diagnostic(JSON.stringify({
    runtime: "local workerd via Miniflare",
    connections: 2,
    quietMilliseconds,
    signedRenewalsPerConnection: rounds,
    activeMilliseconds,
    roundTrips: measures.length,
    ciphertextBytesPerFrame: ciphertext.length,
    latencyP50Milliseconds: measures[Math.floor(measures.length * .50)],
    latencyP95Milliseconds: measures[Math.floor(measures.length * .95)],
  }));
  clientSocket.close();
  serverSocket.close();
});

async function measuredFrame(source, recipient, frame, ciphertext) {
  const arriving = nextWebSocketEvent(recipient, "message");
  source.send(frame);
  const received = Buffer.from((await arriving).data);
  assert.deepEqual(received.subarray(48), ciphertext);
  recipient.send(JSON.stringify({ ack: received.subarray(32, 48).toString("base64url") }));
}
