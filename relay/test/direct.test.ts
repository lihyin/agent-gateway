import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import test, { type TestContext } from "node:test";
import { storePairRecord, deletePair } from "../src/registry.js";
import { exportPKCS8, generateKeyPair } from "jose";
import { build } from "esbuild";
import { Miniflare, createFetchMock } from "miniflare";
import { Bridge } from "../../agent-adapter/src/bridge.js";
import {
  signObject,
  publicIdentity,
  encrypt,
  generateIdentity,
  identityId,
} from "../../agent-adapter/src/crypto.js";
import {
  validatePairRecord,
  issueRoute,
  verifyRequest,
  verifyResult,
  push,
  type DirectEnvironment,
  type Envelope,
} from "../src/direct.js";
import { destinationOperation, registryPair } from "../src/registry.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
const origin = "https://relay.example.com";
async function setup(t: TestContext) {
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
  const env: DirectEnvironment = {
    RELAY_ORIGIN: origin,
    RELAY_ROUTING_KEY: randomBytes(32).toString("base64url"),
  };
  const keys = await generateKeyPair("ES256", { extractable: true });
  Object.assign(env, {
    APNS_KEY_ID: "KEY",
    APNS_TEAM_ID: "TEAM",
    APNS_TOPIC: "com.agentbrain.agentgateway",
    APNS_ENVIRONMENT: "production",
    APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey),
  });
  const fetchMock = createFetchMock();
  fetchMock.disableNetConnect();
  fetchMock
    .get("https://api.push.apple.com")
    .intercept({ path: /\/3\/device\/[a-f0-9]+/, method: "POST" })
    .reply(200, "")
    .persist();
  const bundle = await build({
    entryPoints: [
      new URL("../src/index.ts", import.meta.url).pathname.replace(
        /^\/([A-Za-z]:)/,
        "$1",
      ),
    ],
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
      CHANNELS: { className: "RequestChannel", useSQLite: true },
      PAIRINGS_REGISTRY: { className: "PairingRegistry", useSQLite: true },
    },
    bindings: { ...env },
    fetchMock,
  });
  t.after(() => mf.dispose());
  env.PAIRINGS_REGISTRY = (await mf.getDurableObjectNamespace(
    "PAIRINGS_REGISTRY",
  )) as unknown as DirectEnvironment["PAIRINGS_REGISTRY"];
  await storePairRecord(
    env,
    await validatePairRecord(await bridge.transportConfiguration()),
  );
  const register = {
    version: 1,
    audience: origin,
    issuedAt: now,
    expiresAt: now + 30,
    deviceId: (await bridge.transportConfiguration()).deviceId,
    agentId: (await bridge.transportConfiguration()).agentId,
    pairingEpoch: f.context.pairingEpoch,
    pushToken: "a".repeat(64),
    updatedAt: now * 1000,
  };
  const route = await issueRoute(
    await signObject(f.device, register, "agw+register"),
    env,
    now,
  );
  const job = await bridge.request({
    ...f.payload,
    since: now - 86400,
    until: now,
  });
  return { now, bridge, env, register, route, job, mf };
}
test("automatic routing binds endpoints, audience, epoch and proof expiry", async (t) => {
  const s = await setup(t);
  assert.deepEqual(s.route, { status: "registered" });
  const pairRecord = await s.bridge.transportConfiguration();
  const enrollment = async (identity = f.device) =>
    s.mf.dispatchFetch(`${origin}/v1/pairings/register`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kind: "pairing_record",
        record: pairRecord,
        proof: await signObject(
          identity,
          {
            version: 1,
            audience: origin,
            deviceId: pairRecord.deviceId,
            agentId: pairRecord.agentId,
            pairingEpoch: pairRecord.pairingEpoch,
            issuedAt: s.now,
            expiresAt: s.now + 30,
          },
          "agw+pair-register",
        ),
      }),
    });
  assert.equal((await enrollment()).status, 200);
  assert.equal((await enrollment(f.agent)).status, 401);
  const proof = await s.bridge.relayProof(s.job.requestId, origin);
  assert.deepEqual(
    (await verifyRequest(proof, s.env, s.now)).envelope,
    s.job.envelope,
  );
  await assert.rejects(verifyRequest(proof, s.env, s.now + 30));
  for (const changes of [
    { audience: "https://attacker.example.com" },
    { pairingEpoch: "wrong" },
    { pushToken: "not-a-token" },
    { callback: "https://attacker.example.com" },
  ]) {
    await assert.rejects(
      issueRoute(
        await signObject(
          f.device,
          { ...s.register, ...changes },
          "agw+register",
        ),
        s.env,
        s.now,
      ),
    );
  }
  await assert.rejects(
    issueRoute(
      await signObject(f.agent, s.register, "agw+register"),
      s.env,
      s.now,
    ),
  );
  // A legacy secret must never restore a revoked pairing.
  const pair = await validatePairRecord(
    await s.bridge.transportConfiguration(),
  );
  await deletePair(s.env, pair);
  await assert.rejects(
    verifyRequest(
      proof,
      { ...s.env, ...{ PAIRING_CONFIG: JSON.stringify(pair) } },
      s.now,
    ),
  );
  assert.equal(await storePairRecord(s.env, pair), false);
  assert.equal((await enrollment()).status, 401);
});
test("APNs uses generic alerts, fixed provider, bounded ciphertext and original expiry", async (t) => {
  const s = await setup(t);
  const keys = await generateKeyPair("ES256", { extractable: true });
  const env = {
    ...s.env,
    APNS_KEY_ID: "KEY",
    APNS_TEAM_ID: "TEAM",
    APNS_TOPIC: "com.agentbrain.agentgateway",
    APNS_ENVIRONMENT: "production",
    APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey),
  };
  let providerStatus = 200;
  t.mock.method(
    globalThis,
    "fetch",
    async (url: string, input: RequestInit) => {
      assert.equal(
        url,
        `https://api.push.apple.com/3/device/${s.register.pushToken}`,
      );
      assert.equal(input.redirect, "manual");
      const payload = JSON.parse(input.body as string);
      assert.deepEqual(payload.aps.alert, {
        title: "Agent Gateway",
        body: "An agent requests to access your data",
      });
      assert.equal(payload.aps.badge, 1);
      assert.equal(payload.aps.category, "AGW_DATA_REQUEST");
      assert.deepEqual(payload.agw, s.job.envelope);
      assert.ok(!String(input.body).includes(f.payload.query as string));
      assert.equal(
        new Headers(input.headers).get("apns-expiration"),
        String(s.job.envelope.context.expiresAt),
      );
      return new Response(null, { status: providerStatus });
    },
  );
  await push(env, s.register.pushToken, s.job.envelope);
  for (const status of [302, 403, 500]) {
    providerStatus = status;
    await assert.rejects(push(env, s.register.pushToken, s.job.envelope));
  }
  await assert.rejects(
    push(env, s.register.pushToken, {
      ...s.job.envelope,
      jwe: "x".repeat(4096),
    }),
  );
});

test("destinations survive a day, rotate without agent setup, and reject replay and cross-user requests", async (t) => {
  const s = await setup(t);
  const pair = await validatePairRecord(
    await s.bridge.transportConfiguration(),
  );
  const future = s.now + 2 * 86400;
  const makeRequest = (now: number, changes = {}) =>
    signObject(
      f.agent,
      {
        version: 1,
        audience: origin,
        issuedAt: now,
        expiresAt: now + 30,
        envelope: {
          ...s.job.envelope,
          context: {
            ...s.job.envelope.context,
            issuedAt: now,
            expiresAt: now + 300,
            ...changes,
          },
        },
      },
      "agw+request",
    );
  assert.equal(
    (await verifyRequest(await makeRequest(future), s.env, future)).pushToken,
    "a".repeat(64),
  );
  const rotated = {
    ...s.register,
    issuedAt: future,
    expiresAt: future + 30,
    updatedAt: future * 1000,
    pushToken: "b".repeat(64),
  };
  const update = await signObject(f.device, rotated, "agw+register");
  await issueRoute(update, s.env, future);
  await assert.rejects(issueRoute(update, s.env, future));
  await assert.rejects(
    issueRoute(
      await signObject(
        f.device,
        { ...rotated, updatedAt: rotated.updatedAt - 1 },
        "agw+register",
      ),
      s.env,
      future,
    ),
  );
  assert.equal(
    (await verifyRequest(await makeRequest(future), s.env, future)).pushToken,
    "b".repeat(64),
  );
  // Public metadata cannot reveal the encrypted stored destination.
  const stored = await destinationOperation(s.env, {
    pair,
    action: "resolve",
    now: future,
  });
  assert.ok(!stored.sealed!.includes(rotated.pushToken));
  assert.equal(await storePairRecord(s.env, pair), true);
  assert.equal(
    (await verifyRequest(await makeRequest(future), s.env, future)).pushToken,
    "b".repeat(64),
  );

  const otherDevice = await generateIdentity();
  const otherAgent = await generateIdentity();
  const otherPair = await validatePairRecord({
    deviceSigningKey: publicIdentity(otherDevice).signing,
    agentSigningKey: publicIdentity(otherAgent).signing,
    deviceId: await identityId(otherDevice),
    agentId: await identityId(otherAgent),
    pairingEpoch: "other-epoch",
  });
  assert.equal(
    await storePairRecord(s.env, {
      ...pair,
      deviceId: otherPair.deviceId,
      deviceSigningKey: otherPair.deviceSigningKey,
    }),
    false,
  );
  assert.equal(await storePairRecord(s.env, otherPair), true);
  await issueRoute(
    await signObject(
      otherDevice,
      {
        ...rotated,
        deviceId: otherPair.deviceId,
        agentId: otherPair.agentId,
        pairingEpoch: otherPair.pairingEpoch,
        pushToken: "c".repeat(64),
      },
      "agw+register",
    ),
    s.env,
    future,
  );
  await assert.rejects(
    verifyRequest(
      await makeRequest(future, {
        recipient: otherPair.deviceId,
        pairingEpoch: otherPair.pairingEpoch,
      }),
      s.env,
      future,
    ),
  );
  await assert.rejects(
    issueRoute(
      await signObject(otherDevice, rotated, "agw+register"),
      s.env,
      future,
    ),
  );
  // Re-pairing invalidates the former epoch and clears its destination.
  const replacement = { ...pair, pairingEpoch: "new-epoch" };
  assert.equal(await storePairRecord(s.env, replacement), true);
  await assert.rejects(verifyRequest(await makeRequest(future), s.env, future));
  await assert.rejects(
    destinationOperation(s.env, {
      pair: replacement,
      action: "resolve",
      now: future,
    }),
  );
  assert.equal(await storePairRecord(s.env, pair), false);
  await deletePair(s.env, pair);
  assert.deepEqual(
    await registryPair(s.env, { deviceId: pair.deviceId }),
    replacement,
  );
  // After a user re-pairs, a fresh device registration restores delivery for
  // the new epoch while the old request remains rejected.
  await issueRoute(
    await signObject(
      f.device,
      {
        ...rotated,
        pairingEpoch: replacement.pairingEpoch,
        updatedAt: future * 1000 + 1,
      },
      "agw+register",
    ),
    s.env,
    future,
  );
  assert.equal(
    (
      await verifyRequest(
        await makeRequest(future, { pairingEpoch: replacement.pairingEpoch }),
        s.env,
        future,
      )
    ).pushToken,
    rotated.pushToken,
  );
  await assert.rejects(verifyRequest(await makeRequest(future), s.env, future));
});

test("signed disable and unpair revoke routing; delivery attempts are limited durably", async (t) => {
  const s = await setup(t);
  const pair = await validatePairRecord(
    await s.bridge.transportConfiguration(),
  );
  const request = await s.bridge.relayProof(s.job.requestId, origin);
  for (let i = 0; i < 10; i++) await verifyRequest(request, s.env, s.now);
  await assert.rejects(verifyRequest(request, s.env, s.now), /rate_limited/);
  const control = async (path: string, type: string, identity = f.device) =>
    s.mf.dispatchFetch(`${origin}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/jose" },
      body: await signObject(
        identity,
        {
          version: 1,
          audience: origin,
          deviceId: pair.deviceId,
          agentId: pair.agentId,
          pairingEpoch: pair.pairingEpoch,
          issuedAt: s.now,
          expiresAt: s.now + 30,
          updatedAt: s.now * 1000 + 2,
        },
        type,
      ),
    });
  assert.equal(
    (await control("/v1/routes/disable", "agw+route-disable", f.agent)).status,
    401,
  );
  assert.equal(
    (await control("/v1/routes/disable", "agw+route-disable")).status,
    200,
  );
  await assert.rejects(
    verifyRequest(request, s.env, s.now),
    /transport_unavailable/,
  );
  await assert.rejects(
    issueRoute(
      await signObject(f.device, s.register, "agw+register"),
      s.env,
      s.now,
    ),
  );
  // A later deliberate enable works, but cannot reset the delivery quota.
  await issueRoute(
    await signObject(
      f.device,
      { ...s.register, updatedAt: s.now * 1000 + 3 },
      "agw+register",
    ),
    s.env,
    s.now,
  );
  await assert.rejects(verifyRequest(request, s.env, s.now), /rate_limited/);
  assert.equal(
    (await control("/v1/pairings/revoke", "agw+unpair")).status,
    200,
  );
  assert.equal(
    (await control("/v1/pairings/revoke", "agw+unpair")).status,
    200,
  );
  assert.equal(
    await registryPair(s.env, { deviceId: pair.deviceId }),
    undefined,
  );
  assert.equal(await storePairRecord(s.env, pair), false);
  await assert.rejects(verifyRequest(request, s.env, s.now));
});
test(
  "actual Worker runtime sends notification and returns encrypted approval through Muse's outbound socket",
  { timeout: 60000 },
  async (t) => {
    const s = await setup(t);
    const mf = s.mf;
    try {
      const registration = await mf.dispatchFetch(`${origin}/v1/routes`, {
        method: "POST",
        headers: { "Content-Type": "application/jose" },
        body: await signObject(
          f.device,
          { ...s.register, updatedAt: s.register.updatedAt + 1 },
          "agw+register",
        ),
      });
      assert.equal(registration.status, 200);
      assert.deepEqual(await registration.json(), { status: "registered" });
      const response = await mf.dispatchFetch(`${origin}/v1/requests`, {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${await s.bridge.relayProof(s.job.requestId, origin)}`,
        },
      });
      assert.equal(response.status, 101);
      const socket = response.webSocket!;
      socket.accept();
      const changed = await signObject(
        f.agent,
        {
          version: 1,
          audience: origin,
          issuedAt: s.now,
          expiresAt: s.now + 30,
          envelope: { ...s.job.envelope, jwe: s.job.envelope.jwe + "x" },
        },
        "agw+request",
      );
      assert.equal(
        (
          await mf.dispatchFetch(`${origin}/v1/requests`, {
            headers: {
              Upgrade: "websocket",
              Authorization: `Bearer ${changed}`,
            },
          })
        ).status,
        409,
      );
      const resultReceived = new Promise<Envelope>((resolve) =>
        socket.addEventListener(
          "message",
          (event) => resolve(JSON.parse(event.data as string)),
          { once: true },
        ),
      );
      const c = s.job.envelope.context;
      const encrypted = await encrypt(
        f.device,
        publicIdentity(f.agent),
        { ...c, direction: "result", sender: c.recipient, recipient: c.sender },
        { status: "allowed", messages: [{ subject: "Approved fixture" }] },
      );
      const resultProof = await signObject(
        f.device,
        {
          version: 1,
          audience: origin,
          issuedAt: s.now,
          expiresAt: s.now + 30,
          envelope: encrypted,
        },
        "agw+result",
      );
      assert.deepEqual(
        await verifyResult(resultProof, s.env, s.now),
        encrypted,
      );
      const alteredContext = await signObject(
        f.device,
        {
          version: 1,
          audience: origin,
          issuedAt: s.now,
          expiresAt: s.now + 30,
          envelope: {
            ...encrypted,
            context: {
              ...encrypted.context,
              expiresAt: encrypted.context.expiresAt - 1,
            },
          },
        },
        "agw+result",
      );
      assert.equal(
        (
          await mf.dispatchFetch(`${origin}/v1/results`, {
            method: "POST",
            headers: { "Content-Type": "application/jose" },
            body: alteredContext,
          })
        ).status,
        503,
      );
      const handoff = await mf.dispatchFetch(`${origin}/v1/results`, {
        method: "POST",
        headers: { "Content-Type": "application/jose" },
        body: resultProof,
      });
      assert.equal(handoff.status, 202);
      assert.deepEqual(await s.bridge.submit(await resultReceived), {
        status: "allowed",
        messages: [{ subject: "Approved fixture" }],
      });
      const forged = await signObject(
        f.agent,
        {
          version: 1,
          audience: origin,
          issuedAt: s.now,
          expiresAt: s.now + 30,
          envelope: encrypted,
        },
        "agw+result",
      );
      assert.equal(
        (
          await mf.dispatchFetch(`${origin}/v1/results`, {
            method: "POST",
            headers: { "Content-Type": "application/jose" },
            body: forged,
          })
        ).status,
        401,
      );
      socket.close();
      assert.equal(
        (await mf.dispatchFetch(`${origin}/v1/device/sync`, { method: "POST" }))
          .status,
        404,
      );
    } finally {
      // The test context disposes the Worker runtime.
    }
  },
);
