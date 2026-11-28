import { validateBrowserRequest } from "./passkey-authorization";

const headers = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

export function passkeyPage(mode: "login" | "register", query: URLSearchParams): Response {
  validateBrowserRequest(query);
  const label = mode === "login" ? "Sign in" : "Create a personal account";
  const action = mode === "login" ? "Use passkey" : "Create passkey";
  return new Response(`<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${label} · MyTerm</title>
<link rel="stylesheet" href="/auth/passkey.css">
<main>
  <h1>${label}</h1>
  <button type="button" disabled>${action}</button>
  <p role="status" aria-live="polite">Preparing passkey request…</p>
</main>
<script type="module" src="/auth/passkey.js"></script>
</html>`, { headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
}

export function relayOperatorPage(): Response {
  return new Response(`<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Relay operator · MyTerm</title>
<link rel="stylesheet" href="/auth/passkey.css">
<main>
  <h1>Relay operator</h1>
  <section id="operator-sign-in">
    <label for="bootstrap">Setup token (first-time setup only)</label>
    <input id="bootstrap" type="password" autocomplete="off" spellcheck="false" maxlength="43">
    <button id="prepare" type="button">Prepare passkey</button>
    <button id="verify" type="button" hidden></button>
  </section>
  <section id="operator-session" hidden>
    <button id="issue" type="button">Create one-hour invitation</button>
    <label for="invitation">Invitation</label>
    <input id="invitation" type="text" readonly spellcheck="false" autocomplete="off">
  </section>
  <p role="status" aria-live="polite"></p>
</main>
<script type="module" src="/auth/operator.js"></script>
</html>`, { headers: { ...headers, "Content-Type": "text/html; charset=utf-8" } });
}

export function passkeyStyle(): Response {
  return new Response(`
    body { font-family: system-ui, sans-serif; margin: 0; }
    main { max-width: 25rem; margin: max(3rem, 10vh) auto 0; padding: 1.5rem; }
    h1 { font-size: 1.75rem; }
    button { font: inherit; min-height: 2.75rem; padding: .5rem 1rem; }
    label { display: block; margin-top: 1rem; }
    input { box-sizing: border-box; display: block; font: inherit; margin: .5rem 0 1rem; padding: .5rem; width: 100%; }
  `, { headers: { ...headers, "Content-Type": "text/css; charset=utf-8" } });
}

const moduleHeaders = { ...headers, "Content-Type": "text/javascript; charset=utf-8" };

export function webAuthnScript(): Response {
  return new Response(`
function toBytes(value) {
  return Uint8Array.from(atob(value.replaceAll("-", "+").replaceAll("_", "/")), byte => byte.charCodeAt(0));
}

function toBase64(bytes) {
  let text = "";
  for (const byte of new Uint8Array(bytes)) text += String.fromCharCode(byte);
  return btoa(text).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

export async function post(path, body, bearer) {
  const headers = { "Content-Type": "application/json" };
  if (bearer) headers.Authorization = "Bearer " + bearer;
  const response = await fetch(path, {
    method: "POST",
    headers,
    cache: "no-store",
    credentials: "omit",
    redirect: "error",
    body: JSON.stringify(body),
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error);
  return result;
}

export async function verifyPasskey(options, registering, route, bearer) {
  const { challenge, user, excludeCredentials, allowCredentials, ...rest } = options;
  const publicKey = { ...rest, challenge: toBytes(challenge) };
  if (user) publicKey.user = { ...user, id: toBytes(user.id) };
  if (excludeCredentials) publicKey.excludeCredentials = excludeCredentials.map(key => ({ ...key, id: toBytes(key.id) }));
  if (allowCredentials) publicKey.allowCredentials = allowCredentials.map(key => ({ ...key, id: toBytes(key.id) }));
  const credential = registering ? await navigator.credentials.create({ publicKey }) :
    await navigator.credentials.get({ publicKey });
  if (!credential) throw new Error("passkey_canceled");
  const response = { clientDataJSON: toBase64(credential.response.clientDataJSON) };
  if (registering) {
    response.attestationObject = toBase64(credential.response.attestationObject);
  } else {
    response.authenticatorData = toBase64(credential.response.authenticatorData);
    response.signature = toBase64(credential.response.signature);
    if (credential.response.userHandle) response.userHandle = toBase64(credential.response.userHandle);
  }
  return post(route + "/finish", {
    challenge,
    credential: { id: credential.id, rawId: toBase64(credential.rawId), type: credential.type, response },
  }, bearer);
}
`, { headers: moduleHeaders });
}

export function passkeyScript(): Response {
  return new Response(`
import { post, verifyPasskey } from "/auth/webauthn.js";
const query = new URLSearchParams(location.search);
const fragment = new URLSearchParams(location.hash.slice(1));
const invitation = fragment.get("invitation") || fragment.get("bootstrap_token");
if (location.hash) history.replaceState(null, "", location.pathname + location.search);
const registering = location.pathname === "/auth/register";
const route = registering ? "/v1/passkeys/register" : "/v1/passkeys/login";
const button = document.querySelector("button");
const status = document.querySelector("[role=status]");
const authorization = { redirectUri: query.get("redirect_uri"), codeChallenge: query.get("code_challenge") };

let options;
async function prepare() {
  const { publicKey } = await post(route + "/options", { authorization, invitation });
  options = publicKey;
  button.disabled = false;
}

async function signIn() {
  button.disabled = true;
  status.textContent = "";
  try {
    const { code } = await verifyPasskey(options, registering, route);
    if (typeof code !== "string") throw new Error("code_unavailable");
    const callback = new URL(authorization.redirectUri);
    callback.searchParams.set("code", code);
    callback.searchParams.set("state", query.get("state"));
    location.assign(callback);
  } catch {
    status.textContent = "Passkey verification did not finish. Try again.";
    try {
      await prepare();
    } catch {
      status.textContent = "The passkey request has expired. Start again from MyTerm.";
    }
  }
}

button.addEventListener("click", signIn);
if (!window.PublicKeyCredential || !navigator.credentials) {
  status.textContent = "This browser cannot use passkeys.";
} else {
  try {
    await prepare();
    status.textContent = "";
  } catch (error) {
    status.textContent = error.message === "invitation_required" || error.message === "invitation_unavailable"
      ? "A valid invitation is required."
      : "Could not prepare the passkey request. Start again from MyTerm.";
  }
}
`, { headers: moduleHeaders });
}

export function relayOperatorScript(): Response {
  return new Response(`
import { post, verifyPasskey } from "/auth/webauthn.js";
const setup = document.querySelector("#bootstrap");
const prepare = document.querySelector("#prepare");
const verify = document.querySelector("#verify");
const issue = document.querySelector("#issue");
const invitation = document.querySelector("#invitation");
const status = document.querySelector("[role=status]");
let pending;
let session;

prepare.addEventListener("click", async () => {
  prepare.disabled = true;
  setup.disabled = true;
  verify.hidden = true;
  status.textContent = "Preparing passkey request…";
  const secret = setup.value.trim();
  const route = secret ? "/v1/operator/bootstrap" : "/v1/passkeys/login";
  try {
    const { publicKey } = await post(route + "/options", {}, secret);
    pending = { publicKey, secret, route };
    verify.textContent = secret ? "Create operator passkey" : "Use operator passkey";
    verify.hidden = false;
    verify.focus();
    status.textContent = "";
  } catch (error) {
    status.textContent = error.message === "operator_already_bootstrapped"
      ? "An operator already exists. Clear the setup token and sign in."
      : "Could not prepare operator sign-in. Check the setup token and try again.";
  } finally {
    prepare.disabled = false;
    setup.disabled = false;
  }
});

setup.addEventListener("input", () => {
  verify.hidden = true;
  pending = undefined;
});

verify.addEventListener("click", async () => {
  if (!pending) return;
  const { publicKey, secret, route } = pending;
  pending = undefined;
  verify.disabled = true;
  prepare.disabled = true;
  setup.disabled = true;
  try {
    const accepted = await verifyPasskey(publicKey, Boolean(secret), route, secret);
    if (accepted.role !== "operator") {
      status.textContent = "Use the operator passkey to manage invitations.";
      return;
    }
    session = accepted.session;
    setup.value = "";
    document.querySelector("#operator-sign-in").hidden = true;
    document.querySelector("#operator-session").hidden = false;
    issue.focus();
  } catch {
    status.textContent = "Operator sign-in did not finish. Prepare a new passkey request.";
  } finally {
    verify.hidden = true;
    verify.disabled = false;
    prepare.disabled = false;
    setup.disabled = false;
  }
});

issue.addEventListener("click", async () => {
  if (!session) return;
  issue.disabled = true;
  invitation.value = "";
  try {
    invitation.value = (await post("/v1/operator/invitations", { lifetimeSeconds: 3600 }, session)).token;
    status.textContent = "Share this invitation with the person creating a personal account.";
    invitation.focus();
    invitation.select();
  } catch {
    status.textContent = "Could not create an invitation. An active operator sign-in is required.";
  } finally {
    issue.disabled = false;
  }
});
`, { headers: moduleHeaders });
}
