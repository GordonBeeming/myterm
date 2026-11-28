import {
  generateAuthenticationOptions,
  generateRegistrationOptions,
  verifyAuthenticationResponse,
  verifyRegistrationResponse,
  type AuthenticationResponseJSON,
  type RegistrationResponseJSON,
  type WebAuthnCredential,
} from "@simplewebauthn/server";
import type { Configuration } from "./config";
import { canonicalBase64, fromBase64Url, randomToken, sha256, utf8 } from "./crypto";
import { bearer, error, json, readJson } from "./http";
import { exchangePasskeyCode, nativeAuthorization } from "./passkey-authorization";

const challengeLifetime = 5 * 60 * 1000;
const sessionLifetime = 12 * 60 * 60 * 1000;
const supportedAlgorithms = [-8, -7, -257];

type Role = "personal" | "operator";
type Challenge = {
  user_handle: string | null;
  invitation_hash: string | null;
  code_challenge: string | null;
  redirect_uri: string | null;
};
type Identity = { id: string; role: Role };
type Passkey = Identity & {
  credential_id: string;
  public_key: number[];
  counter: number;
  user_handle: string;
};

export async function loginSession(env: Env, request: Request): Promise<Identity | null> {
  const secret = bearer(request);
  if (!canonicalBase64(secret, 32)) return null;
  return env.ACCOUNT_DB.prepare(
    "SELECT accounts.id, accounts.role FROM login_sessions JOIN accounts ON accounts.id = login_sessions.account_id " +
    "WHERE token_hash = ? AND expires_at > ?",
  ).bind(await sha256(utf8(secret)), Date.now()).first<Identity>();
}

function validCredential(value: unknown): value is Record<string, unknown> & { id: string; response: Record<string, unknown> } {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const data = value as Record<string, unknown>;
  return typeof data.id === "string" && typeof data.rawId === "string" && data.id === data.rawId &&
    /^[A-Za-z0-9_-]{1,1364}$/.test(data.id) && data.type === "public-key" &&
    typeof data.response === "object" && data.response !== null && !Array.isArray(data.response);
}

function registrationCredential(value: unknown): RegistrationResponseJSON | null {
  if (!validCredential(value)) return null;
  const { id, response } = value;
  if (typeof response.clientDataJSON !== "string" || typeof response.attestationObject !== "string") return null;
  return {
    id, rawId: id, type: "public-key", clientExtensionResults: {},
    response: { clientDataJSON: response.clientDataJSON, attestationObject: response.attestationObject },
  };
}

function authenticationCredential(value: unknown): AuthenticationResponseJSON | null {
  if (!validCredential(value)) return null;
  const { id, response } = value;
  if (typeof response.clientDataJSON !== "string" || typeof response.authenticatorData !== "string" ||
      typeof response.signature !== "string" || typeof response.userHandle !== "string") return null;
  return {
    id, rawId: id, type: "public-key", clientExtensionResults: {},
    response: {
      clientDataJSON: response.clientDataJSON, authenticatorData: response.authenticatorData,
      signature: response.signature, userHandle: response.userHandle,
    },
  };
}

function consumedInvitationKey(hash: string): string {
  return "registration-invitations/consumed/v1/" + hash;
}

async function invitationAvailable(env: Env, hash: string): Promise<boolean> {
  const entry = await env.ACCOUNT_DB.prepare(
    "SELECT expires_at FROM registration_invitations WHERE token_hash = ?",
  ).bind(hash).first<{ expires_at: number }>();
  return !!entry && entry.expires_at > Date.now() &&
    await env.SECURITY_CONTROL.head(consumedInvitationKey(hash)) === null;
}

async function registerOptions(
  env: Env, config: Configuration, body: Record<string, unknown>, bootstrap: boolean,
): Promise<Response> {
  const authorization = nativeAuthorization(body.authorization);
  let invitationHash = null;
  if (!bootstrap && config.registration === "invitation") {
    if (!canonicalBase64(body.invitation, 32)) return error(403, "invitation_required");
    invitationHash = await sha256(utf8(body.invitation));
    if (!await invitationAvailable(env, invitationHash)) return error(403, "invitation_unavailable");
  }
  const userHandle = randomToken();
  const challenge = randomToken();
  const publicKey = await generateRegistrationOptions({
    rpName: "MyTerm Relay",
    rpID: config.rpId,
    userName: bootstrap ? "Relay operator" : "MyTerm account",
    userID: fromBase64Url(userHandle),
    challenge: fromBase64Url(challenge),
    timeout: challengeLifetime,
    attestationType: "none",
    authenticatorSelection: { residentKey: "required", userVerification: "required" },
    supportedAlgorithmIDs: supportedAlgorithms,
  });
  await env.ACCOUNT_DB.prepare(
    "INSERT INTO passkey_challenges(challenge, purpose, user_handle, invitation_hash, expires_at, code_challenge, redirect_uri) " +
    "VALUES (?, ?, ?, ?, ?, ?, ?)",
  ).bind(challenge, bootstrap ? "bootstrap" : "register", userHandle, invitationHash, Date.now() + challengeLifetime,
    authorization?.codeChallenge ?? null, authorization?.redirectUri ?? null).run();
  return json({ publicKey });
}

async function consumeChallenge(env: Env, challenge: unknown, purpose: string) {
  if (!canonicalBase64(challenge, 32)) return null;
  return env.ACCOUNT_DB.prepare(
    "DELETE FROM passkey_challenges WHERE challenge = ? AND purpose = ? AND expires_at > ? RETURNING user_handle, invitation_hash, code_challenge, redirect_uri",
  ).bind(challenge, purpose, Date.now()).first<Challenge>();
}

async function authorizationRecord(
  env: Env, claimed: Challenge, accountId: string, now: number,
  passkey?: { id: string; counter: number },
): Promise<{ statement: D1PreparedStatement; body: object }> {
  const secret = randomToken();
  const hash = await sha256(utf8(secret));
  // For login, a concurrent assertion can have advanced the counter after verification.
  const values = passkey ? "SELECT %VALUES% FROM passkeys WHERE id = ? AND counter = ?" : "VALUES (%VALUES%)";
  const bind = (query: string, args: (string | number)[]) => env.ACCOUNT_DB.prepare(query + " " + values.replace(
    "%VALUES%", args.map(() => "?").join(", "),
  )).bind(...args, ...(passkey ? [passkey.id, passkey.counter] : []));

  if (claimed.code_challenge && claimed.redirect_uri) {
    return {
      statement: bind(
        "INSERT INTO passkey_authorization_codes(code_hash, account_id, code_challenge, redirect_uri, expires_at)",
        [hash, accountId, claimed.code_challenge, claimed.redirect_uri, now + 90_000],
      ),
      body: { code: secret },
    };
  }
  const expiresAt = now + sessionLifetime;
  return {
    statement: bind("INSERT INTO login_sessions(token_hash, account_id, expires_at)", [hash, accountId, expiresAt]),
    body: { accountId, session: secret, expiresAt },
  };
}

async function registrationFinish(
  env: Env, config: Configuration, body: Record<string, unknown>, bootstrap: boolean,
): Promise<Response> {
  const credentialResponse = registrationCredential(body.credential);
  const challenge = body.challenge;
  if (!credentialResponse || !canonicalBase64(challenge, 32)) return error(400, "invalid_passkey_response");
  const claimed = await consumeChallenge(env, challenge, bootstrap ? "bootstrap" : "register");
  if (!claimed?.user_handle) return error(401, "invalid_passkey_challenge");

  let credential: WebAuthnCredential;
  try {
    const result = await verifyRegistrationResponse({
      response: credentialResponse, expectedChallenge: challenge, expectedOrigin: config.origin,
      expectedRPID: config.rpId, requireUserVerification: true, supportedAlgorithmIDs: supportedAlgorithms,
    });
    if (!result.verified) return error(401, "passkey_verification_failed");
    credential = result.registrationInfo.credential;
  } catch {
    return error(401, "passkey_verification_failed");
  }

  const accountId = crypto.randomUUID();
  if (claimed.invitation_hash) {
    if (!await invitationAvailable(env, claimed.invitation_hash)) return error(403, "invitation_unavailable");
    // The recovery control bucket stays current even if the account database is restored.
    const consumed = await env.SECURITY_CONTROL.put(consumedInvitationKey(claimed.invitation_hash), accountId, {
      onlyIf: { etagDoesNotMatch: "*" },
      customMetadata: { accountId, consumedAt: String(Date.now()) },
    });
    if (!consumed) return error(403, "invitation_unavailable");
  }

  const now = Date.now();
  const authorization = await authorizationRecord(env, claimed, accountId, now);
  try {
    await env.ACCOUNT_DB.batch([
      env.ACCOUNT_DB.prepare("INSERT INTO accounts(id, role, user_handle, created_at) VALUES (?, ?, ?, ?)")
        .bind(accountId, bootstrap ? "operator" : "personal", claimed.user_handle, now),
      env.ACCOUNT_DB.prepare("INSERT INTO passkeys(id, account_id, public_key, counter) VALUES (?, ?, ?, ?)")
        .bind(credential.id, accountId, credential.publicKey, credential.counter),
      authorization.statement,
    ]);
  } catch (cause) {
    if (String(cause).includes("UNIQUE constraint failed")) return error(409, "registration_conflict");
    throw cause;
  }
  return json({ ...authorization.body, role: bootstrap ? "operator" : "personal" }, 201);
}

async function loginOptions(env: Env, config: Configuration, body: Record<string, unknown>): Promise<Response> {
  const authorization = nativeAuthorization(body.authorization);
  const challenge = randomToken();
  const publicKey = await generateAuthenticationOptions({
    rpID: config.rpId, challenge: fromBase64Url(challenge), timeout: challengeLifetime, userVerification: "required",
  });
  await env.ACCOUNT_DB.prepare(
    "INSERT INTO passkey_challenges(challenge, purpose, expires_at, code_challenge, redirect_uri) VALUES (?, 'login', ?, ?, ?)",
  ).bind(challenge, Date.now() + challengeLifetime, authorization?.codeChallenge ?? null, authorization?.redirectUri ?? null).run();
  return json({ publicKey });
}

async function loginFinish(env: Env, config: Configuration, body: Record<string, unknown>): Promise<Response> {
  const credentialResponse = authenticationCredential(body.credential);
  const challenge = body.challenge;
  if (!credentialResponse || !canonicalBase64(challenge, 32)) return error(400, "invalid_passkey_response");
  const claimed = await consumeChallenge(env, challenge, "login");
  if (!claimed) return error(401, "invalid_passkey_challenge");
  const passkey = await env.ACCOUNT_DB.prepare(
    "SELECT accounts.id, accounts.role, accounts.user_handle, passkeys.id AS credential_id, passkeys.public_key, passkeys.counter " +
    "FROM passkeys JOIN accounts ON accounts.id = passkeys.account_id WHERE passkeys.id = ?",
  ).bind(credentialResponse.id).first<Passkey>();
  if (!passkey || passkey.user_handle !== credentialResponse.response.userHandle) return error(401, "passkey_verification_failed");

  let newCounter: number;
  try {
    const result = await verifyAuthenticationResponse({
      response: credentialResponse, expectedChallenge: challenge, expectedOrigin: config.origin,
      expectedRPID: config.rpId, requireUserVerification: true,
      credential: { id: passkey.credential_id, publicKey: new Uint8Array(passkey.public_key), counter: passkey.counter },
    });
    if (!result.verified) return error(401, "passkey_verification_failed");
    newCounter = result.authenticationInfo.newCounter;
  } catch {
    return error(401, "passkey_verification_failed");
  }

  const authorization = await authorizationRecord(env, claimed, passkey.id, Date.now(), {
    id: passkey.credential_id, counter: passkey.counter,
  });
  const records = await env.ACCOUNT_DB.batch([
    authorization.statement,
    env.ACCOUNT_DB.prepare("UPDATE passkeys SET counter = ? WHERE id = ? AND counter = ?")
      .bind(newCounter, passkey.credential_id, passkey.counter),
  ]);
  if (!records[0]?.meta.changes) return error(401, "passkey_verification_failed");
  return json({ ...authorization.body, role: passkey.role });
}

async function bootstrapAllowed(env: Env, request: Request): Promise<Response | null> {
  const provided = bearer(request);
  const expected = env.RELAY_OPERATOR_BOOTSTRAP;
  if (!canonicalBase64(expected, 32)) return error(503, "operator_bootstrap_unavailable");
  if (!canonicalBase64(provided, 32) || !crypto.subtle.timingSafeEqual(fromBase64Url(provided), fromBase64Url(expected))) {
    return error(401, "operator_bootstrap_unauthorized");
  }
  if (await env.ACCOUNT_DB.prepare("SELECT id FROM accounts WHERE role = 'operator'").first()) {
    return error(409, "operator_already_bootstrapped");
  }
  return null;
}

async function createInvitation(env: Env, request: Request): Promise<Response> {
  if ((await loginSession(env, request))?.role !== "operator") return error(403, "operator_required");
  const { lifetimeSeconds } = await readJson(request);
  if (typeof lifetimeSeconds !== "number" || !Number.isSafeInteger(lifetimeSeconds) ||
      lifetimeSeconds < 60 || lifetimeSeconds > 7 * 24 * 60 * 60) return error(400, "invalid_invitation_lifetime");
  const token = randomToken();
  const expiresAt = Date.now() + lifetimeSeconds * 1000;
  await env.ACCOUNT_DB.prepare("INSERT INTO registration_invitations(token_hash, expires_at) VALUES (?, ?)")
    .bind(await sha256(utf8(token)), expiresAt).run();
  return json({ token, expiresAt }, 201);
}

export async function accountRequest(request: Request, env: Env, config: Configuration, path: string) {
  if (request.method !== "POST") return error(405, "method_not_allowed");
  switch (path) {
    case "/v1/passkeys/register/options":
      return registerOptions(env, config, await readJson(request), false);
    case "/v1/passkeys/register/finish":
      return registrationFinish(env, config, await readJson(request), false);
    case "/v1/passkeys/login/options":
      return loginOptions(env, config, await readJson(request));
    case "/v1/passkeys/login/finish":
      return loginFinish(env, config, await readJson(request));
    case "/v1/passkeys/session":
      return exchangePasskeyCode(env, await readJson(request), sessionLifetime);
    case "/v1/operator/bootstrap/options":
    case "/v1/operator/bootstrap/finish": {
      const denied = await bootstrapAllowed(env, request);
      if (denied) return denied;
      const body = await readJson(request);
      return path.endsWith("/options") ? registerOptions(env, config, body, true) : registrationFinish(env, config, body, true);
    }
    case "/v1/operator/invitations":
      return createInvitation(env, request);
    default:
      return error(404, "route_not_found");
  }
}
