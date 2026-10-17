import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { publicIdentity, identityId } from "../agent-adapter/src/crypto.ts";
import { issueRoute, verifyResult } from "../relay/src/direct.ts";
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
  PAIRING_CONFIG: JSON.stringify(pair),
  RELAY_ROUTING_KEY: randomBytes(32).toString("base64url"),
};
assert.equal((await issueRoute(registration.proof, env, 100)).expiresAt, 86500);
const result = await verifyResult(
  outcome.proof,
  {
    ...env,
    PAIRING_CONFIG: JSON.stringify({ ...pair, pairingEpoch: outcome.epoch }),
  },
  100,
);
assert.equal(result.context.direction, "result");
assert.ok(!JSON.stringify(result).includes("person@example.com"));
console.log(
  "Dart registration and result transport proofs verified by the relay in Node.",
);
