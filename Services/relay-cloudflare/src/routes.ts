import { loginSession } from "./accounts";
import type { Configuration } from "./config";
import { canonicalBase64 } from "./crypto";
import { endpointId } from "./endpoint-proof";
import { bearer, error, parseObject, readBody, readJson } from "./http";
import { purposes, type EndpointPurpose } from "./router";

function purpose(value: unknown): value is EndpointPurpose {
  return typeof value === "string" && [...purposes].some((entry) => entry === value);
}

export async function accountRoute(
  request: Request, env: Env, config: Configuration, accountId: string, route: string,
): Promise<Response> {
  if (route === "/socket") {
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return error(426, "websocket_required");
    }
    if (!canonicalBase64(bearer(request), 32)) return error(401, "connect_ticket_invalid");
    if (!await personalAccountExists(env, accountId)) return error(401, "connect_ticket_invalid");
    return env.ACCOUNT_ROUTER.getByName(accountId).fetch(request);
  }
  if (request.method !== "POST") return error(405, "method_not_allowed");

  if (route === "/suspension") {
    if ((await loginSession(env, request))?.role !== "operator") return error(403, "operator_required");
    if (!await personalAccountExists(env, accountId)) return error(404, "account_not_found");
    const { suspended } = await readJson(request);
    if (typeof suspended !== "boolean") return error(400, "invalid_suspension");
    return env.ACCOUNT_ROUTER.getByName(accountId).suspend(suspended);
  }

  if (route === "/endpoint-challenge") {
    const body = await readJson(request);
    if (!endpointId(body.endpointId) || !purpose(body.purpose)) return error(400, "invalid_endpoint_challenge");
    if (body.purpose === "genesis" && !await ownsAccount(env, request, accountId)) {
      return error(403, "account_session_required");
    }
    if (body.purpose !== "genesis" && !await personalAccountExists(env, accountId)) {
      return error(401, "endpoint_unauthorized");
    }
    return env.ACCOUNT_ROUTER.getByName(accountId).challenge(body.endpointId, body.purpose, body.purpose === "genesis");
  }

  const action = route.startsWith("/actions/") && route.slice("/actions/".length);
  if (!purpose(action)) return error(404, "route_not_found");
  const nonce = request.headers.get("MyTerm-Nonce");
  const signature = request.headers.get("MyTerm-Signature");
  if (!canonicalBase64(nonce, 32) || !canonicalBase64(signature, 64)) return error(401, "endpoint_proof_invalid");
  if (request.headers.get("Content-Type")?.split(";", 1)[0]?.trim().toLowerCase() !== "application/json") {
    return error(415, "unsupported_media_type");
  }
  if (action === "genesis" && !await ownsAccount(env, request, accountId)) {
    return error(403, "account_session_required");
  }
  const payload = await readBody(request, 8 * 1024);
  if (!endpointId(parseObject(payload).endpointId)) return error(400, "invalid_endpoint_id");
  if (action !== "genesis" && !await personalAccountExists(env, accountId)) return error(401, "endpoint_unauthorized");
  return env.ACCOUNT_ROUTER.getByName(accountId).act(config.origin, action, nonce, signature, payload, action === "genesis");
}

async function ownsAccount(env: Env, request: Request, accountId: string): Promise<boolean> {
  const identity = await loginSession(env, request);
  return identity?.id === accountId && identity.role === "personal";
}

async function personalAccountExists(env: Env, accountId: string): Promise<boolean> {
  return !!await env.ACCOUNT_DB.prepare("SELECT id FROM accounts WHERE id = ? AND role = 'personal'")
    .bind(accountId).first();
}
