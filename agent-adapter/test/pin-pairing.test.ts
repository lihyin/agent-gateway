import assert from "node:assert/strict";
import test from "node:test";
import { randomBytes, createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import WebSocket, { WebSocketServer } from "ws";
import { Bridge } from "../src/bridge.js";
import {
  canonical,
  fingerprint,
  identityId,
  publicIdentity,
  signObject,
  verifyObject,
} from "../src/crypto.js";
import { SRP, SrpServer } from "fast-srp-hap";
import {
  parsePairingSetup,
  srpClient,
  sealPairing,
  openPairing,
  pairWithCode,
} from "../src/pin-pairing.js";

const setup = {
  origin: "https://relay.example.com",
  session: "a".repeat(64),
  code: "00123456",
  expiresAt: Math.floor(Date.now() / 1000) + 1800,
};
const line = (value: unknown) =>
  `AGW1.${Buffer.from(JSON.stringify(value)).toString("base64url")}`;
test("setup validates origin, session entropy, code, expiry and fields", () => {
  assert.deepEqual(parsePairingSetup(line(setup)), setup);
  for (const patch of [
    { origin: "http://relay.example.com" },
    { origin: "https://relay.example.com/path" },
    { origin: "https://relay.example.com:123" },
    { session: setup.code },
    { code: "1234" },
    { expiresAt: 0 },
    { expiresAt: setup.expiresAt + 100 },
    { extra: true },
  ]) {
    assert.throws(() => parsePairingSetup(line({ ...setup, ...patch })));
  }
});

test("pairing accepts the thirty-minute boundary and rejects longer or expired codes", () => {
  const now = 1700000000;
  const boundary = { ...setup, expiresAt: now + 1800 };
  assert.deepEqual(parsePairingSetup(line(boundary), now), boundary);
  assert.throws(() =>
    parsePairingSetup(line({ ...boundary, expiresAt: now + 1801 }), now),
  );
  assert.throws(() => parsePairingSetup(line(boundary), boundary.expiresAt));
  assert.deepEqual(
    parsePairingSetup(line({ ...setup, expiresAt: now + 300 }), now),
    { ...setup, expiresAt: now + 300 },
  );
});

for (const replaceExisting of [false, true])
  test(
    `outbound Muse pairing waits for authenticated receipt before saving paired state; replace=${replaceExisting}`,
    { timeout: 15000 },
    async () => {
      const fixture = JSON.parse(
        readFileSync(
          new URL("../../protocol/fixtures/pairing.json", import.meta.url),
          "utf8",
        ),
      );
      const bridge = new Bridge(
        {
          identity: fixture.agent,
          jobs: {},
          ...(replaceExisting
            ? {
                pairing: {
                  identity: publicIdentity(fixture.device),
                  epoch: fixture.context.requestId,
                },
              }
            : {}),
        },
        async () => {},
      );
      const server = new WebSocketServer({ port: 0, host: "127.0.0.1" });
      await new Promise<void>((resolve) => server.once("listening", resolve));
      let peerError: unknown;
      let confirmed!: () => void;
      const confirmation = new Promise<void>((resolve) => {
        confirmed = resolve;
      });
      server.on("connection", (socket) => {
        const params = { ...SRP.params[2048], hash: "sha256" };
        const salt = randomBytes(32);
        const verifier = SRP.computeVerifier(
          params,
          salt,
          Buffer.from(`agw-pin-v1:${setup.origin}:${setup.session}`),
          Buffer.from(setup.code),
        );
        const phone = new SrpServer(params, verifier, randomBytes(32));
        let key: Buffer,
          stage = "proof";
        socket.send(
          JSON.stringify({
            kind: "challenge",
            salt: salt.toString("hex"),
            B: phone.computeB().toString("hex"),
            expiresAt: setup.expiresAt,
          }),
        );
        socket.on("message", async (raw) => {
          try {
            const frame = JSON.parse(raw.toString());
            if (stage === "proof") {
              phone.setA(Buffer.from(frame.A, "hex"));
              phone.checkM1(Buffer.from(frame.M1, "hex"));
              key = phone.computeK();
              stage = "offer";
              socket.send(
                JSON.stringify({ jwe: await sealPairing(key, setup, "ready") }),
              );
            } else if (stage === "offer") {
              assert.equal(
                bridge.state.pairing?.epoch,
                replaceExisting ? fixture.context.requestId : undefined,
              );
              const value = await openPairing(key, setup, frame.jwe, "offer");
              const offer = await verifyObject(
                publicIdentity(fixture.agent).signing,
                value.offer as string,
                "agw+pairing",
              );
              const receipt = await signObject(
                fixture.device,
                {
                  version: 1,
                  kind: "accept",
                  nonce: offer.nonce,
                  offerDigest: createHash("sha256")
                    .update(canonical(value.offer))
                    .digest("hex"),
                  agentId: await identityId(fixture.agent),
                  identity: publicIdentity(fixture.device),
                  epoch: fixture.context.pairingEpoch,
                  issuedAt: Math.floor(Date.now() / 1000),
                  expiresAt: offer.expiresAt,
                },
                "agw+pairing",
              );
              stage = "complete";
              socket.send(
                JSON.stringify({
                  jwe: await sealPairing(key, setup, "receipt", {
                    receipt,
                    fingerprint: fingerprint(publicIdentity(fixture.device)),
                  }),
                }),
              );
            } else {
              await openPairing(key, setup, frame.jwe, "complete");
              assert.ok(bridge.state.pairing);
              confirmed();
            }
          } catch (error) {
            peerError = error;
            confirmed();
            socket.close();
          }
        });
      });
      try {
        const address = server.address() as { port: number };
        await pairWithCode(
          bridge,
          setup,
          undefined,
          (_url, options) =>
            new WebSocket(`ws://127.0.0.1:${address.port}`, options),
          { replaceExisting },
        );
        await confirmation;
        assert.equal(peerError, undefined);
        assert.deepEqual(
          bridge.state.pairing?.identity,
          publicIdentity(fixture.device),
        );
      } finally {
        for (const socket of server.clients) socket.terminate();
        await new Promise<void>((resolve) => server.close(() => resolve()));
      }
    },
  );
test("SRP authenticates one-time code without transmitting it; wrong code and zero public value fail", () => {
  const salt = randomBytes(32);
  const params = { ...SRP.params[2048], hash: "sha256" };
  const verifier = SRP.computeVerifier(
    params,
    salt,
    Buffer.from(`agw-pin-v1:${setup.origin}:${setup.session}`),
    Buffer.from(setup.code),
  );
  const server = new SrpServer(params, verifier, randomBytes(32));
  const client = srpClient(
    setup,
    salt.toString("hex"),
    server.computeB().toString("hex"),
  );
  server.setA(client.computeA());
  server.checkM1(client.computeM1());
  assert.deepEqual(server.computeK(), client.computeK());
  const wrong = srpClient(
    { ...setup, code: "99999999" },
    salt.toString("hex"),
    server.computeB().toString("hex"),
  );
  server.setA(wrong.computeA());
  assert.throws(() => server.checkM1(wrong.computeM1()));
  assert.throws(() => srpClient(setup, salt.toString("hex"), "0".repeat(512)));
});
test("authenticated records bind role, session, origin, expiry and reject tampering", async () => {
  const key = randomBytes(32);
  const compact = await sealPairing(key, setup, "ready");
  assert.equal((await openPairing(key, setup, compact, "ready")).kind, "ready");
  for (const value of [
    { ...setup, session: "b".repeat(64) },
    { ...setup, origin: "https://other.example.com" },
    { ...setup, expiresAt: setup.expiresAt - 1 },
  ])
    await assert.rejects(openPairing(key, value, compact, "ready"));
  await assert.rejects(openPairing(key, setup, compact, "receipt"));
  await assert.rejects(openPairing(randomBytes(32), setup, compact, "ready"));
  const pieces = compact.split(".");
  pieces[3] = (pieces[3][0] === "A" ? "B" : "A") + pieces[3].slice(1);
  await assert.rejects(openPairing(key, setup, pieces.join("."), "ready"));
});
