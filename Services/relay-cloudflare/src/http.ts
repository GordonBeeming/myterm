export function json(data: unknown, status = 200): Response {
  return Response.json(data, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

export function error(status: number, code: string): Response {
  return json({ error: code }, status);
}

export class RelayRequestError extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
  }
}

export async function readBody(request: Request, limit: number): Promise<Uint8Array<ArrayBuffer>> {
  const stream = request.body?.getReader();
  const buffer = new Uint8Array(limit);
  let size = 0;
  if (stream === undefined) return buffer.subarray(0, 0);
  try {
    for (;;) {
      const next = await stream.read();
      if (next.done) break;
      if (next.value.byteLength > limit - size) {
        await stream.cancel();
        throw new RelayRequestError(413, "request_too_large");
      }
      buffer.set(next.value, size);
      size += next.value.byteLength;
    }
    return buffer.subarray(0, size);
  } finally {
    stream.releaseLock();
  }
}

export function parseObject(bytes: Uint8Array): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    throw new RelayRequestError(400, "invalid_json");
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new RelayRequestError(400, "invalid_json");
  }
  return value as Record<string, unknown>;
}

export async function readJson(request: Request): Promise<Record<string, unknown>> {
  if (request.headers.get("Content-Type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    throw new RelayRequestError(415, "unsupported_media_type");
  }
  return parseObject(await readBody(request, 32 * 1024));
}

export function bearer(request: Request): string | undefined {
  const header = request.headers.get("Authorization");
  return header?.match(/^Bearer ([A-Za-z0-9_-]{1,128})$/)?.[1];
}
