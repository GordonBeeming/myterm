import { DurableObject } from "cloudflare:workers";
import { base64Url, canonicalBase64, fromBase64Url, randomToken, sha256, utf8 } from "./crypto";
import { endpointId, validSigningKey, verifyProof } from "./endpoint-proof";
import { bearer, error, json, parseObject, RelayRequestError } from "./http";

const challengeLifetime = 60_000;
const proofInterval = 30_000;
const leaseDuration = 120_000;
const inactivity = 90 * 24 * 60 * 60 * 1000;
const optOutGrace = 30 * 24 * 60 * 60 * 1000;
const maxSockets = 64;
const maxOutstandingBytes = 256 * 1024;
const maxOutstandingFrames = 24;
const maxPayload = 64 * 1024;

type Endpoint = { id: string; signing_key: string; kind: "client" | "server"; relay_enabled: number; revision: number };
type State = { anchor: string | null; suspended: number; last_contact: number | null; grace_deadline: number | null };
type Socket = {
  endpointId: string;
  flowControl: boolean;
  authenticatedAt: number | null;
  openedAt: number;
  probe: string;
  previousProof?: { nonce: string; signature: string };
  nextProbe: number;
  pending: Array<{ token: string; size: number }>;
};

type Challenge = { endpoint_id: string; purpose: string; expires_at: number };
type ConnectTicket = { endpoint_id: string; expires_at: number };
export type EndpointPurpose = "genesis" | "admit" | "revoke" | "connect" | "relay-setting";
export const purposes = new Set<EndpointPurpose>(["genesis", "admit", "revoke", "connect", "relay-setting"]);

function idBytes(id: string): Uint8Array {
  return Uint8Array.from({ length: 32 }, (_, offset) => Number.parseInt(id.slice(offset * 2, offset * 2 + 2), 16));
}

function bytesId(data: Uint8Array): string {
  return Array.from(data, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export class AccountRouter extends DurableObject<Env> {
  private readonly sql: SqlStorage;
  private tail: Promise<unknown> = Promise.resolve();
  private pending = 0;
  private challengeKey?: CryptoKey;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS account_state (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        anchor TEXT,
        suspended INTEGER NOT NULL DEFAULT 0,
        last_contact INTEGER,
        grace_deadline INTEGER
      ) STRICT;
      INSERT OR IGNORE INTO account_state(singleton) VALUES (1);
      CREATE TABLE IF NOT EXISTS account_approver (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        endpoint_id TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS endpoints (
        id TEXT PRIMARY KEY,
        signing_key TEXT NOT NULL,
        kind TEXT NOT NULL CHECK (kind IN ('client', 'server')),
        relay_enabled INTEGER NOT NULL,
        revision INTEGER NOT NULL DEFAULT 0
      ) STRICT;
      CREATE TABLE IF NOT EXISTS endpoint_challenges (
        nonce TEXT PRIMARY KEY,
        endpoint_id TEXT NOT NULL,
        purpose TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS endpoint_challenge_expiry ON endpoint_challenges(expires_at);
      CREATE INDEX IF NOT EXISTS endpoint_challenge_actor ON endpoint_challenges(endpoint_id);
      CREATE TABLE IF NOT EXISTS used_endpoint_challenges (
        nonce TEXT PRIMARY KEY,
        expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS used_endpoint_challenge_expiry ON used_endpoint_challenges(expires_at);
      CREATE TABLE IF NOT EXISTS connect_tickets (
        token_hash TEXT PRIMARY KEY,
        endpoint_id TEXT NOT NULL,
        expires_at INTEGER NOT NULL
      ) STRICT;
      CREATE INDEX IF NOT EXISTS connect_ticket_expiry ON connect_tickets(expires_at);
      CREATE INDEX IF NOT EXISTS connect_ticket_actor ON connect_tickets(endpoint_id);
    `);
  }

  // Durable Object events may interleave while a proof or storage check is pending.
  // A single bounded queue orders changes and delivery across those await points.
  private serialize<T>(work: () => Promise<T> | T): Promise<T> {
    if (this.pending >= 128) throw new RelayRequestError(503, "account_busy");
    this.pending++;
    const previous = this.tail;
    const result = previous.then(work).finally(() => { this.pending--; });
    this.tail = result.then(() => undefined, () => undefined);
    return result;
  }

  private state(): State {
    return this.sql.exec<State>(
      "SELECT anchor, suspended, last_contact, grace_deadline FROM account_state WHERE singleton = 1",
    ).one();
  }

  private endpoint(id: string): Endpoint | undefined {
    return this.sql.exec<Endpoint>("SELECT id, signing_key, kind, relay_enabled, revision FROM endpoints WHERE id = ?", id).toArray()[0];
  }

  private usable(state: State, now: number): boolean {
    return !state.suspended &&
      (state.grace_deadline === null || now < state.grace_deadline) &&
      (state.last_contact === null || now < state.last_contact + inactivity);
  }

  private async challengeTag(actor: string, purpose: EndpointPurpose, prefix: Uint8Array): Promise<Uint8Array> {
    if (!this.challengeKey) {
      let stored = await this.ctx.storage.get<Uint8Array<ArrayBuffer>>("endpoint-challenge-key");
      if (!stored) {
        stored = crypto.getRandomValues(new Uint8Array(32));
        await this.ctx.storage.put("endpoint-challenge-key", stored);
      }
      this.challengeKey = await crypto.subtle.importKey("raw", stored, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    }
    const binding = utf8(["myterm-relay-challenge-v1", this.env.RELAY_ORIGIN, actor, purpose, base64Url(prefix)].join("\n"));
    return new Uint8Array(await crypto.subtle.sign("HMAC", this.challengeKey, binding)).subarray(0, 16);
  }

  private async signedChallengeExpiry(actor: string, purpose: EndpointPurpose, nonce: string): Promise<number | undefined> {
    const bytes = fromBase64Url(nonce);
    const expiry = Number(new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getBigUint64(0));
    if (!Number.isSafeInteger(expiry) || expiry <= Date.now()) return undefined;
    const tag = await this.challengeTag(actor, purpose, bytes.subarray(0, 16));
    let difference = 0;
    for (let index = 0; index < tag.length; index++) difference |= tag[index]! ^ bytes[index + 16]!;
    return difference === 0 ? expiry : undefined;
  }

  challenge(actor: string, purpose: EndpointPurpose, initialAccount: boolean): Promise<Response> {
    return this.serialize(async () => {
      const now = Date.now();
      const state = this.state();
      if (!this.usable(state, now)) return error(401, "endpoint_unauthorized");
      const existing = this.endpoint(actor);
      if (purpose === "genesis") {
        if (!initialAccount || state.anchor !== null) return error(409, "account_initialized");
      } else if (!state.anchor || !existing || (!existing.relay_enabled && purpose !== "relay-setting")) {
        return error(401, "endpoint_unauthorized");
      }
      const expiresAt = now + challengeLifetime;
      // Issuing a challenge does not reserve capacity under an endpoint's identity.
      const nonce = crypto.getRandomValues(new Uint8Array(32));
      new DataView(nonce.buffer).setBigUint64(0, BigInt(expiresAt));
      nonce.set(await this.challengeTag(actor, purpose, nonce.subarray(0, 16)), 16);
      return json({ nonce: base64Url(nonce), expiresAt });
    });
  }

  act(
    origin: string, purpose: EndpointPurpose, nonce: string, signature: string,
    payload: Uint8Array<ArrayBuffer>, initialAccount: boolean,
  ): Promise<Response> {
    return this.serialize(async () => {
      const body = parseObject(payload);
      const actor = body.endpointId;
      if (!endpointId(actor)) return error(400, "invalid_endpoint_id");
      const state = this.state();
      if (!this.usable(state, Date.now())) return error(401, "endpoint_unauthorized");

      const reservation = this.sql.exec<Challenge>(
        "SELECT endpoint_id, purpose, expires_at FROM endpoint_challenges WHERE nonce = ?", nonce,
      ).toArray()[0];
      const expiresAt = reservation
        ? (reservation.endpoint_id === actor && reservation.purpose === purpose ? reservation.expires_at : undefined)
        : await this.signedChallengeExpiry(actor, purpose, nonce);
      const alreadyUsed = this.sql.exec("SELECT nonce FROM used_endpoint_challenges WHERE nonce = ?", nonce).toArray().length > 0;
      if (!expiresAt || expiresAt <= Date.now() || alreadyUsed) {
        return error(401, "endpoint_proof_invalid");
      }

      const endpoint = this.endpoint(actor);
      const anchor = purpose === "genesis" ? body.anchor : state.anchor;
      const key = purpose === "genesis" ? body.signingKey : endpoint?.signing_key;
      if (purpose === "genesis" && (!initialAccount || state.anchor !== null || !await validSigningKey(key, actor))) {
        return error(409, "account_initialized_or_proof_invalid");
      }
      if (!endpointId(anchor) || !canonicalBase64(key, 32) ||
          !await verifyProof(origin, anchor, actor, purpose, nonce, payload, key, signature)) {
        return error(401, "endpoint_proof_invalid");
      }

      const now = Date.now();
      if (expiresAt <= now || !this.usable(state, now)) return error(401, "endpoint_proof_invalid");
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("DELETE FROM endpoint_challenges WHERE expires_at <= ? OR nonce = ?", now, nonce);
        this.sql.exec("DELETE FROM used_endpoint_challenges WHERE expires_at <= ?", now);
        if (!reservation) this.sql.exec("INSERT INTO used_endpoint_challenges VALUES (?, ?)", nonce, expiresAt);
      });

      if (purpose === "genesis") {
        await this.ctx.storage.setAlarm(now + inactivity);
        this.ctx.storage.transactionSync(() => {
          this.sql.exec("INSERT INTO endpoints(id, signing_key, kind, relay_enabled) VALUES (?, ?, 'client', 1)", actor, key);
          this.sql.exec("INSERT INTO account_approver(singleton, endpoint_id) VALUES (1, ?)", actor);
          this.sql.exec("UPDATE account_state SET anchor = ?, last_contact = ? WHERE singleton = 1", anchor, now);
        });
        return json({ anchor, endpointId: actor }, 201);
      }

      if (!endpoint || (!endpoint.relay_enabled && purpose !== "relay-setting")) {
        return error(401, "endpoint_unauthorized");
      }
      if (purpose === "admit" || purpose === "revoke") {
        const approver = this.sql.exec<{ endpoint_id: string }>(
          "SELECT endpoint_id FROM account_approver WHERE singleton = 1",
        ).toArray()[0];
        if (approver?.endpoint_id !== actor) return error(403, "endpoint_approval_required");
      }

      switch (purpose) {
        case "admit":
          return this.admit(body);
        case "revoke":
          return this.revoke(actor, body);
        case "connect":
          return this.createTicket(endpoint.id, now);
        case "relay-setting":
          return this.relaySetting(endpoint, body, state, now);
      }
    });
  }

  private async admit(body: Record<string, unknown>): Promise<Response> {
    const id = body.targetEndpointId;
    const key = body.signingKey;
    const kind = body.kind;
    const enabled = body.relayEnabled;
    if (!endpointId(id) || !canonicalBase64(key, 32) || !await validSigningKey(key, id) ||
        (kind !== "client" && kind !== "server") || typeof enabled !== "boolean" || (kind === "client" && !enabled)) {
      return error(400, "invalid_admission");
    }
    const existing = this.endpoint(id);
    if (existing) {
      if (existing.kind === "client" && !existing.relay_enabled) return error(409, "endpoint_revoked");
      if (existing.kind !== kind || existing.signing_key !== key) return error(409, "endpoint_already_admitted");
      return json({ endpointId: id });
    }
    this.sql.exec(
      "INSERT INTO endpoints(id, signing_key, kind, relay_enabled) VALUES (?, ?, ?, ?)", id, key, kind, Number(enabled),
    );
    return json({ endpointId: id }, 201);
  }

  private revoke(approver: string, body: Record<string, unknown>): Response {
    const id = body.targetEndpointId;
    if (!endpointId(id) || id === approver || this.endpoint(id)?.kind !== "client") {
      return error(400, "invalid_revocation");
    }
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("UPDATE endpoints SET relay_enabled = 0 WHERE id = ?", id);
      this.sql.exec("DELETE FROM endpoint_challenges WHERE endpoint_id = ?", id);
      this.sql.exec("DELETE FROM connect_tickets WHERE endpoint_id = ?", id);
    });
    this.closeSockets(this.ctx.getWebSockets(id), "endpoint access revoked");
    return json({ endpointId: id });
  }

  private async createTicket(id: string, now: number): Promise<Response> {
    this.sql.exec("DELETE FROM connect_tickets WHERE expires_at <= ?", now);
    const ticket = randomToken();
    const expiresAt = now + challengeLifetime;
    const hash = await sha256(utf8(ticket));
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM connect_tickets WHERE endpoint_id = ?", id);
      this.sql.exec("INSERT INTO connect_tickets VALUES (?, ?, ?)", hash, id, expiresAt);
    });
    return json({ ticket, expiresAt });
  }

  private async relaySetting(endpoint: Endpoint, body: Record<string, unknown>, state: State, now: number): Promise<Response> {
    const revision = body.revision;
    const enabled = body.enabled;
    if (endpoint.kind !== "server" || typeof revision !== "number" || !Number.isSafeInteger(revision) ||
        revision < 1 || typeof enabled !== "boolean") return error(400, "invalid_setting");
    if (revision <= endpoint.revision) return json({ revision: endpoint.revision, enabled: !!endpoint.relay_enabled });

    const remaining = this.sql.exec<{ count: number }>(
      "SELECT count(*) AS count FROM endpoints WHERE kind = 'server' AND relay_enabled = 1 AND id <> ?", endpoint.id,
    ).one().count;
    const startsGrace = !enabled && !!endpoint.relay_enabled && remaining === 0;
    const graceDeadline = startsGrace ? now + optOutGrace : state.grace_deadline;
    await this.schedule(now, graceDeadline);
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("UPDATE endpoints SET relay_enabled = ?, revision = ? WHERE id = ?", Number(enabled), revision, endpoint.id);
      this.sql.exec(
        "UPDATE account_state SET last_contact = max(last_contact, ?), grace_deadline = ? WHERE singleton = 1",
        now, graceDeadline,
      );
      if (!enabled) this.sql.exec("DELETE FROM connect_tickets WHERE endpoint_id = ?", endpoint.id);
    });
    if (!enabled) this.closeSockets(this.ctx.getWebSockets(endpoint.id), "relay access disabled");
    return json({ revision, enabled, graceDeadline });
  }

  suspend(suspended: boolean): Promise<Response> {
    return this.serialize(async () => {
      if (suspended) {
        await this.ctx.storage.delete("endpoint-challenge-key");
        this.challengeKey = undefined;
      }
      this.ctx.storage.transactionSync(() => {
        this.sql.exec("UPDATE account_state SET suspended = ? WHERE singleton = 1", Number(suspended));
        if (suspended) {
          this.sql.exec("DELETE FROM endpoint_challenges");
          this.sql.exec("DELETE FROM connect_tickets");
        }
      });
      if (suspended) this.closeSockets(this.ctx.getWebSockets(), "relay access suspended");
      return json({ suspended });
    });
  }

  override fetch(request: Request): Promise<Response> {
    return this.serialize(async () => {
      const ticket = bearer(request);
      if (!canonicalBase64(ticket, 32)) return error(401, "connect_ticket_invalid");
      const hash = await sha256(utf8(ticket));
      const now = Date.now();
      const state = this.state();
      if (!this.usable(state, now)) return error(401, "endpoint_unauthorized");
      const reservation = this.sql.exec<ConnectTicket>(
        "SELECT endpoint_id, expires_at FROM connect_tickets WHERE token_hash = ?", hash,
      ).toArray()[0];
      if (!reservation || reservation.expires_at <= now || !this.endpoint(reservation.endpoint_id)?.relay_enabled) {
        return error(401, "connect_ticket_invalid");
      }
      const existing = this.ctx.getWebSockets(reservation.endpoint_id);
      if (this.ctx.getWebSockets().length >= maxSockets || existing.length >= 2) {
        return error(503, "simultaneous_connection_limit");
      }
      const pair = new WebSocketPair();
      const server = pair[1];
      const connection: Socket = {
        endpointId: reservation.endpoint_id, flowControl: new URL(request.url).searchParams.get("flow") === "1",
        authenticatedAt: null,
        openedAt: Math.max(now, ...existing.map(socket => (socket.deserializeAttachment() as Socket).openedAt + 1)),
        probe: randomToken(), nextProbe: now + proofInterval, pending: [],
      };
      await this.schedule(now, state.grace_deadline, connection.nextProbe);
      this.sql.exec("DELETE FROM connect_tickets WHERE token_hash = ?", hash);
      this.ctx.acceptWebSocket(server, [connection.endpointId]);
      server.serializeAttachment(connection);
      server.send(JSON.stringify({ challenge: "liveness", nonce: connection.probe }));
      return new Response(null, { status: 101, webSocket: pair[0] });
    });
  }

  override async webSocketMessage(webSocket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if ((typeof message === "string" && message.length > 512) ||
        (typeof message !== "string" && message.byteLength > 32 + maxPayload)) {
      this.closeSockets([webSocket], "relay frame too large", 4400);
      return;
    }
    try {
      await this.serialize(async () => {
        if (webSocket.readyState !== WebSocket.OPEN) return;
        const socket: Socket = webSocket.deserializeAttachment();
        const endpoint = this.endpoint(socket.endpointId);
        const now = Date.now();
        const state = this.state();
        if (!endpoint?.relay_enabled || !state.anchor || !this.usable(state, now) ||
            now - (socket.authenticatedAt ?? socket.openedAt) >= leaseDuration) {
          webSocket.close(4403, "relay access denied");
          return;
        }
        if (typeof message === "string") {
          await this.controlFrame(webSocket, socket, endpoint, message, state.anchor, now);
        } else {
          this.forwardFrame(webSocket, socket, endpoint, message, now);
        }
      });
    } catch {
      this.closeSockets([webSocket], "relay frame rejected", 4400);
    }
  }

  private async controlFrame(socket: WebSocket, frame: Socket, endpoint: Endpoint, message: string, anchor: string, now: number) {
    const body = parseObject(utf8(message));
    if (canonicalBase64(body.ack, 16) && frame.pending[0]?.token === body.ack) {
      frame.pending.shift();
      socket.serializeAttachment(frame);
      return;
    }
    if (frame.previousProof && body.nonce === frame.previousProof.nonce && body.proof === frame.previousProof.signature) return;
    if (!frame.probe || body.nonce !== frame.probe || !canonicalBase64(body.proof, 64) ||
        !await verifyProof(this.env.RELAY_ORIGIN, anchor, endpoint.id, "liveness", frame.probe, utf8(""), endpoint.signing_key, body.proof)) {
      socket.close(4401, "liveness proof rejected");
      return;
    }
    if (socket.readyState !== WebSocket.OPEN) return;

    const first = frame.authenticatedAt === null;
    const state = this.state();
    const verifiedAt = Date.now();
    if (!this.usable(state, verifiedAt) || verifiedAt - (frame.authenticatedAt ?? frame.openedAt) >= leaseDuration) {
      socket.close(4403, "relay access expired");
      return;
    }
    const peers = first ? this.ctx.getWebSockets(endpoint.id).filter((candidate) => {
      if (candidate === socket || candidate.readyState !== WebSocket.OPEN) return false;
      return (candidate.deserializeAttachment() as Socket).authenticatedAt !== null;
    }) : [];
    if (peers.some(candidate => (candidate.deserializeAttachment() as Socket).openedAt > frame.openedAt)) {
      socket.close(4409, "relay connection replaced");
      return;
    }
    frame.authenticatedAt = verifiedAt;
    frame.previousProof = { nonce: frame.probe, signature: body.proof };
    frame.probe = "";
    this.sql.exec(
      "UPDATE account_state SET last_contact = max(last_contact, ?), grace_deadline = CASE WHEN ? THEN NULL ELSE grace_deadline END WHERE singleton = 1",
      verifiedAt, Number(first),
    );
    socket.serializeAttachment(frame);
    if (first) {
      this.closeSockets(peers, "relay connection replaced", 4409);
      socket.send(JSON.stringify({ ready: true }));
    }
    await this.schedule(now, first ? null : state.grace_deadline, frame.nextProbe);
  }

  private forwardFrame(socket: WebSocket, frame: Socket, sender: Endpoint, message: ArrayBuffer, now: number): void {
    if (frame.authenticatedAt === null || message.byteLength < 33 || message.byteLength > 32 + maxPayload) {
      socket.close(4400, "invalid relay frame");
      return;
    }
    const input = new Uint8Array(message);
    const destination = bytesId(input.subarray(0, 32));
    const peer = this.endpoint(destination);
    if (!peer?.relay_enabled || peer.kind === sender.kind) {
      socket.send(JSON.stringify({ unavailable: destination }));
      return;
    }
    const deliverTo = this.ctx.getWebSockets(destination).find((candidate) => {
      if (candidate.readyState !== WebSocket.OPEN) return false;
      const attachment: Socket = candidate.deserializeAttachment();
      return attachment.authenticatedAt !== null && now - attachment.authenticatedAt < leaseDuration;
    });
    if (!deliverTo) {
      socket.send(JSON.stringify({ unavailable: destination }));
      return;
    }
    const receiver: Socket = deliverTo.deserializeAttachment();
    const bytes = message.byteLength + 16;
    const outstanding = receiver.pending.reduce((total, item) => total + item.size, 0);
    if (receiver.pending.length >= maxOutstandingFrames || bytes > maxOutstandingBytes - outstanding) {
      if (frame.flowControl) {
        socket.send(JSON.stringify({ deferred: destination }));
        return;
      }
      socket.close(4429, "relay receiver has no queue capacity");
      return;
    }

    const receipt = crypto.getRandomValues(new Uint8Array(16));
    const outbound = new Uint8Array(bytes);
    outbound.set(idBytes(sender.id), 0);
    outbound.set(receipt, 32);
    outbound.set(input.subarray(32), 48);
    receiver.pending.push({ token: base64Url(receipt), size: bytes });
    deliverTo.serializeAttachment(receiver);
    deliverTo.send(outbound);
    if (frame.flowControl) socket.send(JSON.stringify({ queued: destination }));
  }

  private closeSockets(sockets: WebSocket[], reason: string, code = 4403) {
    for (const socket of sockets) {
      if (socket.readyState === WebSocket.OPEN) socket.close(code, reason);
    }
  }

  override webSocketClose(socket: WebSocket, code: number) {
    if (socket.readyState === WebSocket.CLOSED || code === 1006) return;
    if (code === 1005) socket.close();
    else socket.close(code);
  }

  override webSocketError(socket: WebSocket) {
    this.closeSockets([socket], "relay socket failed", 1011);
  }

  private async schedule(now: number, graceDeadline: number | null, probe = Number.POSITIVE_INFINITY) {
    const time = Math.min(now + inactivity, graceDeadline ?? Number.POSITIVE_INFINITY, probe);
    const scheduled = await this.ctx.storage.getAlarm();
    if (scheduled === null || scheduled > time) await this.ctx.storage.setAlarm(time);
  }

  override async alarm(): Promise<void> {
    await this.serialize(async () => {
      const now = Date.now();
      const state = this.state();
      const deadline = Math.min(state.grace_deadline ?? Number.POSITIVE_INFINITY, (state.last_contact ?? now) + inactivity);
      if (now >= deadline) {
        this.closeSockets(this.ctx.getWebSockets(), "relay access expired");
        return;
      }
      let next = deadline;
      for (const socket of this.ctx.getWebSockets()) {
        if (socket.readyState !== WebSocket.OPEN) continue;
        const frame: Socket = socket.deserializeAttachment();
        const expiry = (frame.authenticatedAt ?? frame.openedAt) + leaseDuration;
        if (now >= expiry) {
          socket.close(4401, "liveness proof expired");
          continue;
        }
        if (now >= frame.nextProbe) {
          // Keep an unanswered nonce until the lease ends so a response in flight stays valid.
          if (!frame.probe) frame.probe = randomToken();
          socket.send(JSON.stringify({ challenge: "liveness", nonce: frame.probe }));
          frame.nextProbe = now + proofInterval;
          socket.serializeAttachment(frame);
        }
        next = Math.min(next, frame.nextProbe, expiry);
      }
      await this.ctx.storage.setAlarm(next);
    });
  }
}
