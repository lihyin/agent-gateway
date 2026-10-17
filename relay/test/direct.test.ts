import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import test from "node:test";
import { exportPKCS8, generateKeyPair } from "jose";
import { build } from "esbuild";
import { Miniflare, createFetchMock } from "miniflare";
import { Bridge } from "../../agent-adapter/src/bridge.js";
import {
  signObject,
  publicIdentity,
  encrypt,
} from "../../agent-adapter/src/crypto.js";
import {
  issueRoute,
  verifyRequest,
  verifyResult,
  push,
  type DirectEnvironment,
  type Envelope,
} from "../src/direct.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
const origin = "https://relay.example.com";
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
  const env: DirectEnvironment = {
    RELAY_ORIGIN: origin,
    PAIRING_CONFIG: JSON.stringify(await bridge.transportConfiguration()),
    RELAY_ROUTING_KEY: randomBytes(32).toString("base64url"),
  };
  const register = {
    version: 1,
    audience: origin,
    issuedAt: now,
    expiresAt: now + 30,
    deviceId: (await bridge.transportConfiguration()).deviceId,
    agentId: (await bridge.transportConfiguration()).agentId,
    pairingEpoch: f.context.pairingEpoch,
    pushToken: "a".repeat(64),
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
  return { now, bridge, env, register, route, job };
}
test("route encryption and signed transport bind both endpoints, audience, epoch and expiry", async () => {
  const s = await setup();
  assert.ok(!s.route.route.includes(s.register.pushToken));
  const proof = await s.bridge.relayProof(
    s.job.requestId,
    s.route.route,
    origin,
  );
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
  await assert.rejects(
    verifyRequest(
      await s.bridge.relayProof(
        s.job.requestId,
        s.route.route.slice(0, -4) + "xxxx",
        origin,
      ),
      s.env,
      s.now,
    ),
  );
  await assert.rejects(
    verifyRequest(
      proof,
      {
        ...s.env,
        PAIRING_CONFIG: JSON.stringify({
          ...JSON.parse(s.env.PAIRING_CONFIG!),
          pairingEpoch: "revoked",
        }),
      },
      s.now,
    ),
  );
});
test("APNs uses generic alerts, fixed provider, bounded ciphertext and original expiry", async (t) => {
  const s = await setup();
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
test(
  "actual Worker runtime sends notification and returns encrypted approval through Muse's outbound socket",
  { timeout: 60000 },
  async () => {
    const s = await setup();
    const keys = await generateKeyPair("ES256", { extractable: true });
    const fetchMock = createFetchMock();
    fetchMock.disableNetConnect();
    fetchMock
      .get("https://api.push.apple.com")
      .intercept({ path: `/3/device/${s.register.pushToken}`, method: "POST" })
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
      },
      bindings: {
        ...s.env,
        APNS_KEY_ID: "KEY",
        APNS_TEAM_ID: "TEAM",
        APNS_TOPIC: "com.agentbrain.agentgateway",
        APNS_ENVIRONMENT: "production",
        APNS_PRIVATE_KEY: await exportPKCS8(keys.privateKey),
      },
      fetchMock,
    });
    try {
      const registration = await mf.dispatchFetch(`${origin}/v1/routes`, {
        method: "POST",
        headers: { "Content-Type": "application/jose" },
        body: await signObject(f.device, s.register, "agw+register"),
      });
      assert.equal(registration.status, 200);
      const route = (await registration.json()) as { route: string };
      const response = await mf.dispatchFetch(`${origin}/v1/requests`, {
        headers: {
          Upgrade: "websocket",
          Authorization: `Bearer ${await s.bridge.relayProof(s.job.requestId, route.route, origin)}`,
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
          route: route.route,
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
      await mf.dispose();
    }
  },
);
