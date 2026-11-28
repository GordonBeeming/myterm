import { accountRequest } from "./accounts";
import { configuration } from "./config";
import { error, json, RelayRequestError } from "./http";

import { accountRoute } from "./routes";
import { passkeyPage, passkeyScript, passkeyStyle, relayOperatorPage, relayOperatorScript, webAuthnScript }
  from "./passkey-page";
export { AccountRouter } from "./router";

export default {
  async fetch(request, env) {
    const config = configuration(env);
    if (!config) return error(503, "relay_configuration_invalid");
    const url = new URL(request.url);
    const origin = request.headers.get("Origin");
    if (url.origin !== config.origin || (origin !== null && origin !== config.origin)) {
      return error(421, "relay_origin_mismatch");
    }
    if (request.method === "GET" && url.pathname === "/v1/capabilities") {
      return json({ protocol: 1, schema: 2, revision: config.revision, channel: config.channel,
        features: ["passkeys", "native-passkey-pkce-v1", "approved-endpoint-relay-v1", "frame-flow-control-v1"] });
    }
    try {
      if (request.method === "GET") {
        if (url.pathname === "/auth/login") return passkeyPage("login", url.searchParams);
        if (url.pathname === "/auth/register") return passkeyPage("register", url.searchParams);
        if (url.pathname === "/auth/passkey.js") return passkeyScript();
        if (url.pathname === "/auth/passkey.css") return passkeyStyle();
        if (url.pathname === "/auth/operator") return relayOperatorPage();
        if (url.pathname === "/auth/operator.js") return relayOperatorScript();
        if (url.pathname === "/auth/webauthn.js") return webAuthnScript();
      }
      const scoped = url.pathname.match(/^\/v1\/accounts\/([a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12})(\/[^?]+)$/);
      if (scoped?.[1] && scoped[2]) return await accountRoute(request, env, config, scoped[1], scoped[2]);
      return await accountRequest(request, env, config, url.pathname);
    } catch (cause) {
      if (cause instanceof RelayRequestError) return error(cause.status, cause.code);
      console.error(JSON.stringify({ event: "relay_request_failed" }));
      return error(503, "relay_unavailable");
    }
  },
} satisfies ExportedHandler<Env>;
