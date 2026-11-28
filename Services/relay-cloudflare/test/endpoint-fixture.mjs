import { createHash, generateKeyPairSync, randomBytes, sign } from "node:crypto";

const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");

export class Endpoint {
  keys = generateKeyPairSync("ed25519");
  publicKey = this.keys.publicKey.export({ format: "jwk" }).x;
  id = hash(Buffer.from(this.publicKey, "base64url"));

  signature(origin, anchor, purpose, nonce, body = "") {
    const message = ["myterm-relay-endpoint-v1", origin, anchor, this.id, purpose, nonce, hash(body)].join("\n");
    return sign(null, Buffer.from(message), this.keys.privateKey).toString("base64url");
  }
}

export const newAnchor = () => randomBytes(32).toString("hex");

export async function action(relay, origin, accountId, anchor, endpoint, purpose, fields = {}, session) {
  const authorization = session ? { Authorization: "Bearer " + session } : {};
  const headers = { "Content-Type": "application/json", ...authorization };
  const base = origin + "/v1/accounts/" + accountId;
  const nonceResponse = await relay.dispatchFetch(base + "/endpoint-challenge", {
    method: "POST", headers,
    body: JSON.stringify({ endpointId: endpoint.id, purpose }),
  });
  if (nonceResponse.status !== 200) return nonceResponse;
  const { nonce } = await nonceResponse.json();
  const body = JSON.stringify({ endpointId: endpoint.id, ...fields });
  return relay.dispatchFetch(base + "/actions/" + purpose, {
    method: "POST",
    headers: { ...headers, "MyTerm-Nonce": nonce, "MyTerm-Signature": endpoint.signature(origin, anchor, purpose, nonce, body) },
    body,
  });
}

export function nextWebSocketEvent(socket, event, timeout = 5000) {
  return new Promise((resolve, reject) => {
    const signal = AbortSignal.timeout(timeout);
    const abort = () => reject(new Error("Timed out waiting for WebSocket " + event));
    signal.addEventListener("abort", abort, { once: true });
    socket.addEventListener(event, (value) => {
      signal.removeEventListener("abort", abort);
      resolve(value);
    }, { once: true, signal });
  });
}

export async function connect(relay, origin, accountId, anchor, endpoint) {
  const authorized = await action(relay, origin, accountId, anchor, endpoint, "connect");
  if (authorized.status !== 200) throw new Error("Socket ticket failed: " + authorized.status);
  const { ticket } = await authorized.json();
  const response = await relay.dispatchFetch(origin + "/v1/accounts/" + accountId + "/socket", {
    headers: { Upgrade: "websocket", Authorization: "Bearer " + ticket },
  });
  if (response.status !== 101 || !response.webSocket) throw new Error("Socket upgrade failed: " + response.status);
  const socket = response.webSocket;
  const first = nextWebSocketEvent(socket, "message");
  socket.accept();
  const challenge = JSON.parse((await first).data);
  const ready = nextWebSocketEvent(socket, "message");
  socket.send(JSON.stringify({ proof: endpoint.signature(origin, anchor, "liveness", challenge.nonce), nonce: challenge.nonce }));
  if (!JSON.parse((await ready).data).ready) throw new Error("Socket did not authenticate");
  return socket;
}
