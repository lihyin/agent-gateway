import { build } from "esbuild";
import { createRequire } from "node:module";
import { storePairRecord } from "../relay/src/registry.ts";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { publicIdentity, identityId } from "../agent-adapter/src/crypto.ts";
import { issueRoute, verifyResult } from "../relay/src/direct.ts";
// Match the relay's pinned test runtime, rather than Wrangler's hoisted alpha.
const { Miniflare } = createRequire(
  new URL("../relay/package.json", import.meta.url),
)("miniflare");
const fixture = JSON.parse(
  await readFile("protocol/fixtures/pairing.json", "utf8"),
);
const registration = JSON.parse(
  await readFile("mobile/.dart_tool/direct-register.json", "utf8"),
);
const outcome = JSON.parse(
  await readFile("mobile/.dart_tool/direct-result.json", "utf8"),
);
const pair = {
  deviceSigningKey: publicIdentity(fixture.device).signing,
  agentSigningKey: publicIdentity(fixture.agent).signing,
  deviceId: await identityId(fixture.device),
  agentId: await identityId(fixture.agent),
  pairingEpoch: registration.epoch,
};
const env = {
  RELAY_ORIGIN: "https://relay.example.com",
  RELAY_ROUTING_KEY: randomBytes(32).toString("base64url"),
};
const bundle = await build({
  entryPoints: ["relay/src/index.ts"],
  bundle: true,
  format: "esm",
  platform: "browser",
  write: false,
});
const mf = new Miniflare({
  modules: true,
  script: bundle.outputFiles[0].text,
  compatibilityDate: "2026-08-06",
  durableObjects: {
    PAIRINGS_REGISTRY: { className: "PairingRegistry", useSQLite: true },
  },
});
try {
  env.PAIRINGS_REGISTRY =
    await mf.getDurableObjectNamespace("PAIRINGS_REGISTRY");
  assert.equal(await storePairRecord(env, pair), true);
  assert.deepEqual(await issueRoute(registration.proof, env, 100), {
    status: "registered",
  });
  assert.equal(
    await storePairRecord(env, { ...pair, pairingEpoch: outcome.epoch }),
    true,
  );
  const result = await verifyResult(outcome.proof, env, 100);
  assert.equal(result.context.direction, "result");
  assert.ok(!JSON.stringify(result).includes("person@example.com"));
  console.log(
    "Dart registration and result transport proofs verified by the relay in Node.",
  );
} finally {
  await mf.dispose();
}
