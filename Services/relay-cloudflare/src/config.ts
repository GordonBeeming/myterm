const hostedOrigins = {
  beta: "https://myterm-relay-beta.gordonbeeming.dev",
  live: "https://myterm-relay.gordonbeeming.dev",
};

export function relayIdentity(channel: string, publicOrigin: string, rpId: string, registration: string, revision: string) {
  const origin = URL.parse(publicOrigin);
  if (!origin || origin.origin !== publicOrigin || origin.hostname !== rpId) return null;
  if (registration !== "public" && registration !== "invitation") return null;

  if (channel === "local") {
    if (origin.protocol !== "http:" || rpId !== "localhost" || revision !== "local") return null;
  } else {
    if (origin.protocol !== "https:" || origin.port || !/^[a-f0-9]{40}$/.test(revision) ||
        !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(rpId)) return null;
    if (rpId === "myterm-relay-dev.gordonbeeming.dev") return null;
    if (channel === "beta" || channel === "live") {
      if (origin.origin !== hostedOrigins[channel] || registration !== "public") return null;
    } else if (channel !== "self-hosted" || Object.values(hostedOrigins).includes(origin.origin)) {
      return null;
    }
  }

  return { channel, origin: origin.origin, rpId, registration, revision };
}

export function configuration(env: Env) {
  if (!env.ACCOUNT_DB || !env.ACCOUNT_ROUTER || !env.SECURITY_CONTROL) return null;
  return relayIdentity(env.RELAY_CHANNEL, env.RELAY_ORIGIN, env.RELAY_RP_ID, env.RELAY_REGISTRATION, env.RELAY_REVISION);
}

export type Configuration = NonNullable<ReturnType<typeof configuration>>;
