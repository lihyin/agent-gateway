import assert from "node:assert/strict";
import test from "node:test";
import { requireTransportConfig } from "./require-relay-transport-config.mjs";

const privateNames = ["RELAY_ROUTING_KEY", "APNS_PRIVATE_KEY"];
const publicNames = [
  "APNS_KEY_ID",
  "APNS_TEAM_ID",
  "APNS_TOPIC",
  "APNS_ENVIRONMENT",
];
const bindings = [
  ...privateNames.map((name) => ({ name, type: "secret_text" })),
  ...publicNames.map((name) => ({
    name,
    type: "plain_text",
    text: "configured-value",
  })),
];
const options = {
  accountId: "account",
  token: "test-token",
  environment: "production",
};
const fetchBindings = (data) => async () =>
  Response.json({ success: true, result: { bindings: data } });

test("transport preflight accepts public Variables or Secrets and exposes only names", async () => {
  for (const data of [
    bindings,
    bindings.map((binding) => ({ name: binding.name, type: "secret_text" })),
  ]) {
    const names = await requireTransportConfig({
      ...options,
      fetchImpl: fetchBindings(data),
    });
    assert.deepEqual(names, [...privateNames, ...publicNames]);
    assert.ok(!JSON.stringify(names).includes("configured-value"));
  }
});
test("transport preflight rejects missing bindings, plaintext private keys, and API failure", async () => {
  await assert.rejects(
    requireTransportConfig({
      ...options,
      fetchImpl: fetchBindings(bindings.slice(1)),
    }),
    /missing Worker bindings: RELAY_ROUTING_KEY/,
  );
  await assert.rejects(
    requireTransportConfig({
      ...options,
      fetchImpl: fetchBindings(
        bindings.map((binding) => ({
          ...binding,
          type: "plain_text",
          text: "do-not-print",
        })),
      ),
    }),
    /must be Secrets: RELAY_ROUTING_KEY, APNS_PRIVATE_KEY/,
  );
  await assert.rejects(
    requireTransportConfig({
      ...options,
      fetchImpl: async () => new Response("", { status: 403 }),
    }),
    /HTTP 403/,
  );
});
