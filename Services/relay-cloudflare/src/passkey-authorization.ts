import { base64Url, canonicalBase64, randomToken, sha256, utf8 } from "./crypto";
import { error, json, RelayRequestError } from "./http";

const redirectUris = new Set([
  "myterm-companion://auth/callback",
  "myterm-companion-dev://auth/callback",
  "myterm://companion-auth/callback",
  "myterm-dev://companion-auth/callback",
]);

export type NativeAuthorization = { codeChallenge: string; redirectUri: string };

export function nativeAuthorization(value: unknown): NativeAuthorization | null {
  if (value === undefined) return null;
  if (!value || typeof value !== "object" ||
      !("codeChallenge" in value) || !canonicalBase64(value.codeChallenge, 32) ||
      !("redirectUri" in value) || typeof value.redirectUri !== "string" || !redirectUris.has(value.redirectUri)) {
    throw new RelayRequestError(400, "invalid_authorization_request");
  }
  return { codeChallenge: value.codeChallenge, redirectUri: value.redirectUri };
}

export function validateBrowserRequest(query: URLSearchParams): void {
  for (const key of ["state", "code_challenge", "code_challenge_method", "redirect_uri"]) {
    if (query.getAll(key).length !== 1) throw new RelayRequestError(400, "invalid_authorization_request");
  }
  if (!canonicalBase64(query.get("state"), 32) || query.get("code_challenge_method") !== "S256") {
    throw new RelayRequestError(400, "invalid_authorization_request");
  }
  nativeAuthorization({ codeChallenge: query.get("code_challenge"), redirectUri: query.get("redirect_uri") });
}

export async function exchangePasskeyCode(
  env: Env, body: Record<string, unknown>, sessionLifetime: number,
): Promise<Response> {
  const { code, codeVerifier, redirectUri } = body;
  if (!canonicalBase64(code, 32) || typeof codeVerifier !== "string" ||
      !/^[A-Za-z0-9._~-]{43,128}$/.test(codeVerifier) ||
      typeof redirectUri !== "string" || !redirectUris.has(redirectUri)) {
    return error(400, "invalid_authorization_exchange");
  }
  const session = randomToken();
  const [codeHash, verifierHash, sessionHash] = await Promise.all([
    sha256(utf8(code)),
    crypto.subtle.digest("SHA-256", utf8(codeVerifier)),
    sha256(utf8(session)),
  ]);
  const codeChallenge = base64Url(new Uint8Array(verifierHash));
  const expiresAt = Date.now() + sessionLifetime;
  const records = await env.ACCOUNT_DB.batch<{ account_id: string }>([
    env.ACCOUNT_DB.prepare(
      "INSERT INTO login_sessions(token_hash, account_id, expires_at) " +
      "SELECT ?, account_id, ? FROM passkey_authorization_codes " +
      "WHERE code_hash = ? AND code_challenge = ? AND redirect_uri = ? AND expires_at > unixepoch('subsec') * 1000",
    ).bind(sessionHash, expiresAt, codeHash, codeChallenge, redirectUri),
    env.ACCOUNT_DB.prepare(
      "DELETE FROM passkey_authorization_codes " +
      "WHERE code_hash = ? AND EXISTS (SELECT 1 FROM login_sessions WHERE token_hash = ?) RETURNING account_id",
    ).bind(codeHash, sessionHash),
  ]);
  const accountId = records[1]?.results[0]?.account_id;
  return accountId ? json({ accountId, session, expiresAt }) : error(401, "invalid_authorization_code");
}
