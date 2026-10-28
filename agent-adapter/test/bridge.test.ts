import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { Bridge, type BridgeState } from "../src/bridge.js";
import {
  decrypt,
  encrypt,
  fingerprint,
  identityId,
  publicIdentity,
  signObject,
  verifyObject,
  canonical,
  type Context,
} from "../src/crypto.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
const now = 100;
function setup(paired = true) {
  const state: BridgeState = {
    identity: f.agent,
    jobs: {},
    ...(paired
      ? {
          pairing: {
            identity: publicIdentity(f.device),
            epoch: f.context.pairingEpoch,
          },
        }
      : { offer: f.offer }),
  };
  return new Bridge(
    state,
    async () => {},
    () => now,
  );
}
test("encrypted request uses pinned recipient and validated payload", async () => {
  const bridge = setup();
  const job = await bridge.request(f.payload);
  assert.equal(job.status, "pending_device_review");
  assert.deepEqual(
    await decrypt(
      f.device,
      publicIdentity(f.agent),
      job.envelope,
      job.envelope.context,
      now,
    ),
    f.payload,
  );
  assert.equal(
    (await bridge.status(job.requestId)).status,
    "pending_device_review",
  );
  for (const p of [
    { ...f.payload, operation: "get" },
    { ...f.payload, token: "secret" },
    { ...f.payload, query: "*" },
    { ...f.payload, fields: ["body"] },
  ])
    await assert.rejects(bridge.request(p));
  await assert.rejects(setup(false).request(f.payload));
});

test("explicit re-pairing retains the old pair until authenticated acceptance and clears old jobs", async () => {
  const bridge = setup();
  const oldIdentity = structuredClone(bridge.state.identity);
  const oldPair = structuredClone(bridge.state.pairing);
  const job = await bridge.request(f.payload);
  await assert.rejects(bridge.offer(), /already_paired/);
  const { offer } = await bridge.offer(true);
  assert.deepEqual(bridge.state.pairing, oldPair);
  assert.ok(bridge.state.jobs[job.requestId]);
  const value = await verifyObject(
    publicIdentity(f.agent).signing,
    offer,
    "agw+pairing",
  );
  const { createHash, randomUUID } = await import("node:crypto");
  const epoch = randomUUID();
  const receipt = await signObject(
    f.device,
    {
      version: 1,
      kind: "accept",
      nonce: value.nonce,
      offerDigest: createHash("sha256").update(canonical(offer)).digest("hex"),
      agentId: await identityId(f.agent),
      identity: publicIdentity(f.device),
      epoch,
      issuedAt: now,
      expiresAt: value.expiresAt,
    },
    "agw+pairing",
  );
  await assert.rejects(
    bridge.accept(receipt, fingerprint(publicIdentity(f.device))),
  );
  await assert.rejects(bridge.accept(receipt, "0".repeat(64), undefined, true));
  await assert.rejects(
    bridge.accept(
      receipt,
      fingerprint(publicIdentity(f.device)),
      () => false,
      true,
    ),
  );
  assert.deepEqual(bridge.state.pairing, oldPair);
  assert.ok(bridge.state.jobs[job.requestId]);
  await bridge.accept(
    receipt,
    fingerprint(publicIdentity(f.device)),
    () => true,
    true,
  );
  assert.equal(bridge.state.pairing?.epoch, epoch);
  assert.deepEqual(bridge.state.identity, oldIdentity);
  assert.deepEqual(bridge.state.jobs, {});
  await assert.rejects(bridge.status(job.requestId), /unknown_request/);
  await assert.rejects(
    bridge.accept(
      receipt,
      fingerprint(publicIdentity(f.device)),
      undefined,
      true,
    ),
  );
});
test("results bind request identity, direction, pairing and signature", async () => {
  const bridge = setup();
  const job = await bridge.request(f.payload);
  const c = job.envelope.context;
  const context: Context = {
    ...c,
    direction: "result",
    sender: c.recipient,
    recipient: c.sender,
  };
  const result = await encrypt(f.device, publicIdentity(f.agent), context, {
    status: "allowed",
    messages: [{ subject: "Filtered" }],
  });
  assert.deepEqual(await bridge.submit(result), {
    status: "allowed",
    messages: [{ subject: "Filtered" }],
  });
  assert.deepEqual(await bridge.submit(result), {
    status: "allowed",
    messages: [{ subject: "Filtered" }],
  });
  const alternate = await encrypt(f.device, publicIdentity(f.agent), context, {
    status: "denied",
    messages: [],
  });
  await assert.rejects(bridge.submit(alternate), /replay/);
  for (const changed of [
    { ...result, context: { ...context, pairingEpoch: f.context.requestId } },
    { ...result, context: { ...context, direction: "request" as const } },
    { ...result, jwe: result.jwe.slice(0, -5) + "AAAAA" },
  ])
    await assert.rejects(bridge.submit(changed));
  await bridge.unpair();
  await assert.rejects(bridge.submit(result));
});
test("pairing receipt rejects wrong fingerprint, nonce, digest and expired receipts", async () => {
  const bridge = setup(false);
  const { createHash } = await import("node:crypto");
  const payload = {
    version: 1,
    kind: "accept",
    nonce: JSON.parse(
      Buffer.from(f.offer.split(".")[1], "base64url").toString(),
    ).nonce,
    offerDigest: createHash("sha256")
      .update(JSON.stringify(f.offer))
      .digest("hex"),
    agentId: await identityId(f.agent),
    identity: publicIdentity(f.device),
    epoch: f.context.pairingEpoch,
    issuedAt: 100,
    expiresAt: 400,
  };
  const receipt = await signObject(f.device, payload, "agw+pairing");
  await assert.rejects(bridge.accept(receipt, "0".repeat(64)));
  for (const altered of [
    { ...payload, nonce: "other" },
    { ...payload, offerDigest: "wrong" },
    { ...payload, expiresAt: 100 },
    { ...payload, identity: publicIdentity(f.agent) },
  ])
    await assert.rejects(
      bridge.accept(
        await signObject(f.device, altered, "agw+pairing"),
        fingerprint(publicIdentity(f.device)),
      ),
    );
  await bridge.accept(receipt, fingerprint(publicIdentity(f.device)));
  assert.equal(bridge.state.pairing?.epoch, f.context.pairingEpoch);
  await assert.rejects(
    bridge.accept(receipt, fingerprint(publicIdentity(f.device))),
  );
});
test("storage failure disables future operations and capacity is bounded", async () => {
  const b = setup();
  const failed = new Bridge(
    b.state,
    async () => {
      throw new Error("disk");
    },
    () => 100,
  );
  await assert.rejects(failed.request(f.payload), /storage_unavailable/);
  await assert.rejects(failed.request(f.payload), /storage_unavailable/);
  const full = setup();
  for (let i = 0; i < 20; i++) await full.request(f.payload);
  await assert.rejects(full.request(f.payload), /capacity/);
});
