// MyTerm Relay
//
// A rendezvous pipe: a Mac keeps one outbound WebSocket to this relay under a
// rendezvous id, a phone connects naming the same id, and the relay joins
// them and forwards binary frames both ways. The relay never interprets the
// bytes it forwards -- they are TLS ciphertext end to end. One Durable
// Object instance owns each rendezvous id.

export interface Env {
  RENDEZVOUS: DurableObjectNamespace;
}

/** Rendezvous ids and host keys: opaque strings, 16-128 chars, [A-Za-z0-9_-] only. */
const ID_RE = /^[A-Za-z0-9_-]{16,128}$/;

/** Session ids are relay-generated 16-byte hex strings, but validate shape defensively anyway. */
const SID_RE = /^[A-Za-z0-9_-]{1,128}$/;

const HOST_CONTROL_RE = /^\/v1\/host\/([^/]+)$/;
const HOST_SESSION_RE = /^\/v1\/host\/([^/]+)\/session\/([^/]+)$/;
const DEVICE_RE = /^\/v1\/device\/([^/]+)$/;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function textResponse(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "content-type": "text/plain" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;

    if (request.method === "GET" && pathname === "/") {
      return textResponse("myterm relay");
    }

    if (request.method === "GET" && pathname === "/v1/health") {
      return jsonResponse({ ok: true });
    }

    const hostSessionMatch = pathname.match(HOST_SESSION_RE);
    if (hostSessionMatch) {
      const [, id, sid] = hostSessionMatch;
      const validation = validateHostRequest(request, id);
      if (validation) return validation;
      if (!SID_RE.test(sid)) return textResponse("bad session id", 400);
      const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(id));
      return stub.fetch(request);
    }

    const hostControlMatch = pathname.match(HOST_CONTROL_RE);
    if (hostControlMatch) {
      const [, id] = hostControlMatch;
      const validation = validateHostRequest(request, id);
      if (validation) return validation;
      const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(id));
      return stub.fetch(request);
    }

    const deviceMatch = pathname.match(DEVICE_RE);
    if (deviceMatch) {
      const [, id] = deviceMatch;
      if (!ID_RE.test(id)) return textResponse("bad rendezvous id", 400);
      if (request.headers.get("Upgrade") !== "websocket") {
        return textResponse("expected websocket upgrade", 426);
      }
      const stub = env.RENDEZVOUS.get(env.RENDEZVOUS.idFromName(id));
      return stub.fetch(request);
    }

    return textResponse("not found", 404);
  },
};

function validateHostRequest(request: Request, id: string): Response | null {
  if (!ID_RE.test(id)) return textResponse("bad rendezvous id", 400);
  const key = request.headers.get("X-MyTerm-Host-Key");
  if (!key || !ID_RE.test(key)) return textResponse("missing or bad host key", 400);
  if (request.headers.get("Upgrade") !== "websocket") {
    return textResponse("expected websocket upgrade", 426);
  }
  return null;
}

/** Frames larger than this close the offending socket with code 1009. */
const MAX_FRAME_BYTES = 1 * 1024 * 1024;

/** Total bytes buffered for a device while its host session socket is not yet connected. */
const MAX_BUFFERED_BYTES = 64 * 1024;

/** A rendezvous id may have at most this many pending/open sessions at once. */
const MAX_SESSIONS = 16;

/** How long a device waits for the host to open its session socket. */
const HOST_ANSWER_TIMEOUT_MS = 10_000;

type SessionState = "pending" | "joined";

interface Session {
  state: SessionState;
  deviceSocket: WebSocket;
  hostSocket: WebSocket | null;
  buffer: ArrayBuffer[];
  bufferedBytes: number;
  /** Reading a Blob is asynchronous. Frames from each side are handled on one chain per side, so
   *  a slow one can never overtake the next; a TLS stream does not survive reordering. */
  deviceOrder: Promise<void>;
  hostOrder: Promise<void>;
  answerTimeout: ReturnType<typeof setTimeout> | null;
}

// A binary message arrives as an ArrayBuffer, a view, or a Blob depending on the runtime and its
// compatibility flags, and only a plain ArrayBuffer is forwarded intact: a view goes out as an
// empty frame and a Blob as the text "[object Blob]". Everything is normalised to an ArrayBuffer.
async function toBytes(data: unknown): Promise<ArrayBuffer | null> {
  if (typeof data === "string") return null;
  if (data instanceof ArrayBuffer) return data;
  if (ArrayBuffer.isView(data)) {
    return data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) as ArrayBuffer;
  }
  if (data instanceof Blob) return await data.arrayBuffer();
  return null;
}

/** One Durable Object instance per rendezvous id. Backed by SQLite storage (see migrations). */
export class Rendezvous implements DurableObject {
  private readonly state: DurableObjectState;
  private hostKey: string | null = null;
  private hostKeyLoaded: Promise<void>;
  private controlSocket: WebSocket | null = null;
  private readonly sessions = new Map<string, Session>();
  private sessionsHandled = 0;

  constructor(state: DurableObjectState, _env: Env) {
    this.state = state;
    this.hostKeyLoaded = this.state.storage.get<string>("hostKey").then((stored) => {
      this.hostKey = stored ?? null;
    });
  }

  async fetch(request: Request): Promise<Response> {
    await this.hostKeyLoaded;
    const url = new URL(request.url);
    const { pathname } = url;

    const hostSessionMatch = pathname.match(HOST_SESSION_RE);
    if (hostSessionMatch) {
      return this.handleHostSession(request, hostSessionMatch[2]);
    }

    const hostControlMatch = pathname.match(HOST_CONTROL_RE);
    if (hostControlMatch) {
      return this.handleHostControl(request);
    }

    const deviceMatch = pathname.match(DEVICE_RE);
    if (deviceMatch) {
      return this.handleDevice(request);
    }

    return textResponse("not found", 404);
  }

  /** First key seen for this id wins and is persisted; later mismatched keys are rejected. */
  private async authorizeHostKey(request: Request): Promise<boolean> {
    const key = request.headers.get("X-MyTerm-Host-Key") ?? "";
    if (this.hostKey === null) {
      this.hostKey = key;
      await this.state.storage.put("hostKey", key);
      return true;
    }
    return this.hostKey === key;
  }

  private async handleHostControl(request: Request): Promise<Response> {
    if (!(await this.authorizeHostKey(request))) {
      return textResponse("forbidden", 403);
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    // Close any existing control socket. Do this before adopting the new one so its
    // close handler (which only cleans up when it is still the current socket) is a no-op.
    if (this.controlSocket) {
      try {
        this.controlSocket.close(4001, "replaced");
      } catch {
        // already closed
      }
    }
    this.controlSocket = server;

    server.addEventListener("message", (event: MessageEvent) => {
      if (typeof event.data !== "string") return;
      let msg: unknown;
      try {
        msg = JSON.parse(event.data);
      } catch {
        return;
      }
      if (msg && typeof msg === "object" && (msg as { type?: unknown }).type === "ping") {
        server.send(JSON.stringify({ type: "pong" }));
      }
    });

    server.addEventListener("close", () => {
      if (this.controlSocket !== server) return;
      this.controlSocket = null;
      for (const [sid, session] of this.sessions) {
        if (session.state === "pending") {
          this.teardownSession(sid, session, 4004, "host offline");
        }
      }
    });

    server.addEventListener("error", () => {
      // Surfaced to the peer via the eventual close event; nothing else to do here.
    });

    // Sessions announced to the socket this one replaced are still waiting, and their timers are
    // still running. The Mac that just arrived is the one that can answer them.
    for (const [sid, session] of this.sessions) {
      if (session.state === "pending") {
        server.send(JSON.stringify({ type: "open", session: sid }));
      }
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleHostSession(request: Request, sid: string): Promise<Response> {
    if (!(await this.authorizeHostKey(request))) {
      return textResponse("forbidden", 403);
    }

    const session = this.sessions.get(sid);
    if (!session || session.state !== "pending") {
      return textResponse("no such pending session", 404);
    }

    if (session.answerTimeout) {
      clearTimeout(session.answerTimeout);
      session.answerTimeout = null;
    }

    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    session.state = "joined";
    session.hostSocket = server;
    this.sessionsHandled += 1;

    // Flush anything the device sent while we were waiting for the host, in order.
    for (const chunk of session.buffer) {
      server.send(chunk);
    }
    session.buffer = [];
    session.bufferedBytes = 0;

    server.addEventListener("message", (event: MessageEvent) => {
      const pending = toBytes(event.data);
      session.hostOrder = session.hostOrder.then(async () => {
      let bytes: ArrayBuffer | null;
      try {
        bytes = await pending;
      } catch {
        return; // the socket went away while its frame was still being read
      }
      if (bytes === null) return; // text frames on a session socket are ignored
      if (bytes.byteLength > MAX_FRAME_BYTES) {
        server.close(1009, "frame too large");
        return;
      }
      try {
        session.deviceSocket.send(bytes);
      } catch {
        // device socket already gone; its close handler will clean up.
      }
      });
    });

    server.addEventListener("close", () => {
      this.teardownSession(sid, session, 1000, "peer closed");
    });

    server.addEventListener("error", () => {});

    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleDevice(request: Request): Promise<Response> {
    const pair = new WebSocketPair();
    const client = pair[0];
    const server = pair[1];
    server.accept();

    if (!this.controlSocket) {
      server.close(4004, "host offline");
      return new Response(null, { status: 101, webSocket: client });
    }

    if (this.sessions.size >= MAX_SESSIONS) {
      server.close(4029, "too many sessions");
      return new Response(null, { status: 101, webSocket: client });
    }

    const sid = randomSessionId();
    const session: Session = {
      state: "pending",
      deviceSocket: server,
      hostSocket: null,
      buffer: [],
      bufferedBytes: 0,
      deviceOrder: Promise.resolve(),
      hostOrder: Promise.resolve(),
      answerTimeout: null,
    };
    this.sessions.set(sid, session);

    server.addEventListener("message", (event: MessageEvent) => {
      const pending = toBytes(event.data);
      session.deviceOrder = session.deviceOrder.then(async () => {
      let bytes: ArrayBuffer | null;
      try {
        bytes = await pending;
      } catch {
        return; // the socket went away while its frame was still being read
      }
      if (bytes === null) return; // text frames on a session socket are ignored
      if (bytes.byteLength > MAX_FRAME_BYTES) {
        server.close(1009, "frame too large");
        return;
      }
      if (session.state === "joined" && session.hostSocket) {
        try {
          session.hostSocket.send(bytes);
        } catch {
          // host socket already gone; its close handler will clean up.
        }
        return;
      }
      session.bufferedBytes += bytes.byteLength;
      if (session.bufferedBytes > MAX_BUFFERED_BYTES) {
        server.close(1009, "buffer overflow");
        return;
      }
      session.buffer.push(bytes);
      });
    });

    server.addEventListener("close", () => {
      this.teardownSession(sid, session, 1000, "peer closed");
    });

    server.addEventListener("error", () => {});

    try {
      this.controlSocket.send(JSON.stringify({ type: "open", session: sid }));
    } catch {
      this.sessions.delete(sid);
      server.close(4004, "host offline");
      return new Response(null, { status: 101, webSocket: client });
    }

    session.answerTimeout = setTimeout(() => {
      const current = this.sessions.get(sid);
      if (current && current.state === "pending") {
        this.sessions.delete(sid);
        try {
          current.deviceSocket.close(4008, "host did not answer");
        } catch {
          // already closed
        }
      }
    }, HOST_ANSWER_TIMEOUT_MS);

    return new Response(null, { status: 101, webSocket: client });
  }

  /** Removes a session and closes whichever side is still open. Idempotent per session object. */
  private teardownSession(
    sid: string,
    session: Session,
    code: number,
    reason: string,
  ): void {
    if (this.sessions.get(sid) !== session) return;
    this.sessions.delete(sid);
    if (session.answerTimeout) {
      clearTimeout(session.answerTimeout);
      session.answerTimeout = null;
    }
    try {
      session.deviceSocket.close(code, reason);
    } catch {
      // already closed
    }
    if (session.hostSocket) {
      try {
        session.hostSocket.close(code, reason);
      } catch {
        // already closed
      }
    }
  }
}

function randomSessionId(): string {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}
