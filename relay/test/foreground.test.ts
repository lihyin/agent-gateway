import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import worker, { type RelayEnvironment } from "../src/index.js";
import {
  boundedText,
  publicOrigin,
  verifySyncProof,
  type PairingConfiguration,
} from "../src/foreground.js";
import { Bridge } from "../../agent-adapter/src/bridge.js";
import {
  identityId,
  publicIdentity,
  signObject,
  encrypt,
} from "../../agent-adapter/src/crypto.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
const origin = "https://relay.example.com";
test("upstream connection failures return transport errors", async (t) => {
  const s = await setup();
  t.mock.method(globalThis, "fetch", async () => {
    throw new TypeError("connection failed");
  });
  const response = await worker.fetch(await s.request(), s.env);
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "transport_unavailable" });
});
async function setup() {
  const now = Math.floor(Date.now() / 1000);
  const bridge = new Bridge(
    {
      identity: f.agent,
      pairing: {
        identity: publicIdentity(f.device),
        epoch: f.context.pairingEpoch,
      },
      jobs: {},
    },
    async () => {},
    () => now,
  );
  const pair = (await bridge.transportConfiguration()) as PairingConfiguration;
  const proof = {
    version: 1,
    audience: origin,
    deviceId: pair.deviceId,
    agentId: pair.agentId,
    pairingEpoch: pair.pairingEpoch,
    issuedAt: now,
    expiresAt: now + 30,
    knownRequests: [] as string[],
    result: null as unknown,
  };
  const env: RelayEnvironment = {
    RELAY_ORIGIN: origin,
    BRIDGE_ORIGIN: "https://bridge.example.com",
    BRIDGE_RELAY_TOKEN: "r".repeat(40),
    PAIRING_CONFIG: JSON.stringify(pair),
  };
  const signed = (changes = {}) =>
    signObject(f.device, { ...proof, ...changes }, "agw+sync");
  const request = async (changes = {}) =>
    new Request(`${origin}/v1/device/sync`, {
      method: "POST",
      headers: { "Content-Type": "application/jose" },
      body: await signed(changes),
    });
  return { now, bridge, pair, proof, env, signed, request };
}
test("relay transfers only ciphertext; approval, denial and duplicate handoff use pinned bridge verification", async (t) => {
  const s = await setup();
  const job = await s.bridge.request({
    ...f.payload,
    since: s.now - 86400,
    until: s.now,
  });
  let calls = 0;
  t.mock.method(
    globalThis,
    "fetch",
    async (url: string, options: RequestInit) => {
      calls++;
      assert.equal(url, "https://bridge.example.com/transport/sync");
      assert.equal(options.redirect, "error");
      assert.equal(
        (options.headers as Record<string, string>).Authorization,
        `Bearer ${s.env.BRIDGE_RELAY_TOKEN}`,
      );
      return Response.json(await s.bridge.sync(options.body as string, origin));
    },
  );
  let response = await worker.fetch(await s.request(), s.env);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    acknowledged: null,
    envelope: job.envelope,
  });
  response = await worker.fetch(
    await s.request({ knownRequests: [job.requestId] }),
    s.env,
  );
  assert.deepEqual(await response.json(), {
    acknowledged: null,
    envelope: null,
  });
  for (const status of ["allowed", "denied"]) {
    const next =
      status === "allowed"
        ? job
        : await s.bridge.request({
            ...f.payload,
            since: s.now - 86400,
            until: s.now,
          });
    const c = next.envelope.context;
    const result = await encrypt(
      f.device,
      publicIdentity(f.agent),
      { ...c, direction: "result", sender: c.recipient, recipient: c.sender },
      {
        status,
        messages:
          status === "allowed"
            ? [{ subject: "Approved synthetic subject" }]
            : [],
      },
    );
    for (let retry = 0; retry < 2; retry++) {
      response = await worker.fetch(await s.request({ result }), s.env);
      const text = await response.text();
      assert.equal(response.status, 200);
      assert.ok(!text.includes("Approved synthetic subject"));
      assert.equal(JSON.parse(text).acknowledged, next.requestId);
    }
    assert.equal((await s.bridge.status(next.requestId)).status, status);
  }
  assert.equal(calls, 6);
});
test("wrong keys, epochs, audiences, stale proofs and schema extensions fail before forwarding", async (t) => {
  const s = await setup();
  let calls = 0;
  t.mock.method(globalThis, "fetch", async () => {
    calls++;
    throw new Error("should not forward");
  });
  for (const changes of [
    { pairingEpoch: "00000000-0000-4000-8000-000000000000" },
    { audience: "https://other.example.com" },
    { issuedAt: s.now - 40, expiresAt: s.now - 10 },
    { expiresAt: s.now + 31 },
    { deviceId: await identityId(f.agent) },
    { callback: "https://attacker.example.com" },
    { knownRequests: Array(21).fill(f.context.requestId) },
  ]) {
    assert.equal(
      (await worker.fetch(await s.request(changes), s.env)).status,
      401,
    );
    await assert.rejects(s.bridge.sync(await s.signed(changes), origin));
  }
  const wrong = await signObject(f.agent, s.proof, "agw+sync");
  await assert.rejects(verifySyncProof(wrong, s.pair, origin, s.now));
  const tampered = (await s.signed()).split(".");
  tampered[1] = Buffer.from(
    JSON.stringify({ ...s.proof, expiresAt: s.now + 300 }),
  ).toString("base64url");
  await assert.rejects(s.bridge.sync(tampered.join("."), origin));
  assert.equal(calls, 0);
});
test("forwarding rejects redirects, plaintext replies, oversized data and unconfigured origins", async (t) => {
  const s = await setup();
  let output: unknown = { messages: [{ subject: "not encrypted" }] };
  t.mock.method(globalThis, "fetch", async () => Response.json(output));
  assert.equal((await worker.fetch(await s.request(), s.env)).status, 503);
  output = {
    acknowledged: null,
    envelope: { context: {}, jwe: "x".repeat(9000) },
  };
  assert.equal((await worker.fetch(await s.request(), s.env)).status, 413);
  for (const value of [
    "http://bridge.example.com",
    "https://127.0.0.1",
    "https://[::1]",
    "https://a.local",
    "https://user@bridge.example.com",
    "https://bridge.example.com/path",
  ])
    assert.throws(() => publicOrigin(value));
  assert.equal(
    (
      await worker.fetch(await s.request(), {
        ...s.env,
        BRIDGE_ORIGIN: "https://127.0.0.1",
      })
    ).status,
    503,
  );
  await assert.rejects(boundedText(new Response("x".repeat(100)), 10));
  const oversized = new Request(`${origin}/v1/device/sync`, {
    method: "POST",
    headers: { "Content-Type": "application/jose" },
    body: "x".repeat(92001),
  });
  assert.equal((await worker.fetch(oversized, s.env)).status, 413);
});
