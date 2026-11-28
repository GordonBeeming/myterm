import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, relative, resolve } from "node:path";
import { parseArgs } from "node:util";
import { relayIdentity } from "../src/config.ts";

async function main() {
  const { values } = parseArgs({
    options: {
      channel: { type: "string" },
      origin: { type: "string" },
      revision: { type: "string" },
      "account-id": { type: "string" },
      "database-id": { type: "string" },
      name: { type: "string" },
      registration: { type: "string" },
    },
  });
  const { channel, origin, revision, name, registration, "account-id": accountId, "database-id": databaseId } = values;
  if (channel !== "beta" && channel !== "live" && channel !== "self-hosted") {
    throw new Error("Select beta, live or self-hosted.");
  }
  if (!/^[a-f0-9]{32}$/.test(accountId ?? "")) throw new Error("A valid Cloudflare account ID is required.");
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(databaseId ?? "")) {
    throw new Error("A valid D1 database ID is required.");
  }

  const root = resolve(import.meta.dirname, "..");
  const local = JSON.parse(await readFile(resolve(root, "wrangler.jsonc"), "utf8"));
  if (local.d1_databases.some(({ database_id }) => database_id === databaseId)) {
    throw new Error("Supply a D1 database for this deployment.");
  }
  const mode = registration ?? (channel === "self-hosted" ? "invitation" : "public");
  const identity = relayIdentity(channel, origin ?? "", URL.parse(origin ?? "")?.hostname ?? "", mode, revision ?? "");
  if (!identity) throw new Error("Check the relay channel, HTTPS origin, registration mode and immutable revision.");

  const workerName = channel === "self-hosted" ? name : "myterm-relay-" + channel;
  const reservedNames = ["myterm-relay-local", "myterm-relay-dev", "myterm-relay-beta", "myterm-relay-live"];
  if (!workerName || !/^[a-z][a-z0-9-]{2,37}[a-z0-9]$/.test(workerName) ||
      (channel === "self-hosted" && reservedNames.includes(workerName)) ||
      (channel !== "self-hosted" && name !== undefined)) {
    throw new Error("Use a distinct Worker name for a self-hosted installation.");
  }

  const output = resolve(root, ".wrangler", "deploy", workerName + ".json");
  const directory = dirname(output);
  const resourcePath = (path) => relative(directory, resolve(root, path));
  const manifest = {
    ...local,
    $schema: resourcePath(local.$schema),
    main: resourcePath(local.main),
    account_id: accountId,
    name: workerName,
    routes: [{ pattern: identity.rpId, custom_domain: true }],
    vars: {
      RELAY_CHANNEL: identity.channel,
      RELAY_ORIGIN: identity.origin,
      RELAY_RP_ID: identity.rpId,
      RELAY_REGISTRATION: identity.registration,
      RELAY_REVISION: identity.revision,
    },
    d1_databases: [{
      binding: "ACCOUNT_DB", database_name: workerName, database_id: databaseId,
      migrations_dir: resourcePath("migrations"),
    }],
    r2_buckets: [{ binding: "SECURITY_CONTROL", bucket_name: workerName + "-security-control" }],
  };
  await mkdir(directory, { recursive: true });
  await writeFile(output, JSON.stringify(manifest, null, 2) + "\n");
  console.log(relative(process.cwd(), output));
}

try {
  await main();
} catch (cause) {
  console.error(cause instanceof Error ? cause.message : "Could not prepare relay configuration.");
  process.exitCode = 1;
}
