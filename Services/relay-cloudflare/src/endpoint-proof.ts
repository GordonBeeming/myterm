import { canonicalBase64, fromBase64Url, sha256, utf8 } from "./crypto";

export function endpointId(value: unknown): value is string {
  return typeof value === "string" && /^[a-f0-9]{64}$/.test(value);
}

export async function validSigningKey(key: unknown, id: string): Promise<boolean> {
  return canonicalBase64(key, 32) && await sha256(fromBase64Url(key)) === id;
}

export async function verifyProof(
  origin: string, anchor: string, actor: string, purpose: string, nonce: string,
  payload: Uint8Array<ArrayBuffer>, key: string, signature: string,
): Promise<boolean> {
  try {
    const message = ["myterm-relay-endpoint-v1", origin, anchor, actor, purpose, nonce, await sha256(payload)].join("\n");
    return await crypto.subtle.verify(
      "Ed25519", await crypto.subtle.importKey("raw", fromBase64Url(key), "Ed25519", false, ["verify"]),
      fromBase64Url(signature), utf8(message),
    );
  } catch {
    return false;
  }
}
