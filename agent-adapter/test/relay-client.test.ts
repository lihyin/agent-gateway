import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFileSync } from "node:fs";
import test from "node:test";
import WebSocket, { WebSocketServer } from "ws";
import { Bridge } from "../src/bridge.js";
import { encrypt, publicIdentity, verifyObject } from "../src/crypto.js";
import { relayRequest } from "../src/relay-client.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
test("outbound agent client verifies approved/denied ciphertext and reuses its durable job", async () => {
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
  const server = createServer();
  const sockets = new WebSocketServer({ server });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address() as { port: number };
  try {
    for (const status of ["allowed", "denied"]) {
      const job = await bridge.request({
        ...f.payload,
        since: now - 86400,
        until: now,
      });
      const c = job.envelope.context;
      const result = await encrypt(
        f.device,
        publicIdentity(f.agent),
        { ...c, direction: "result", sender: c.recipient, recipient: c.sender },
        {
          status,
          messages:
            status === "allowed" ? [{ subject: "Approved fixture" }] : [],
        },
      );
      sockets.once("connection", (socket) => {
        socket.send(JSON.stringify(result));
      });
      let connections = 0;
      const connect = (url: string, options: WebSocket.ClientOptions) => {
        assert.equal(url, "wss://relay.example.com/v1/requests");
        assert.equal(options.followRedirects, false);
        connections++;
        return new WebSocket(`ws://127.0.0.1:${address.port}`, options);
      };
      const signed = await bridge.relayProof(
        job.requestId,
        "sealed-route",
        "https://relay.example.com",
      );
      assert.deepEqual(
        (
          await verifyObject(
            publicIdentity(f.agent).signing,
            signed,
            "agw+request",
          )
        ).envelope,
        job.envelope,
      );
      const outcome = await relayRequest(
        bridge,
        job.requestId,
        "https://relay.example.com",
        "sealed-route",
        undefined,
        connect,
      );
      assert.equal(outcome.status, status);
      assert.equal(connections, 1);
      assert.deepEqual(
        await relayRequest(
          bridge,
          job.requestId,
          "https://relay.example.com",
          "sealed-route",
          undefined,
          connect,
        ),
        outcome,
      );
      assert.equal(connections, 1);
    }
  } finally {
    for (const socket of sockets.clients) socket.terminate();
    await new Promise<void>((resolve) => sockets.close(() => resolve()));
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
});
test("cancelled outbound work cannot become a completed disclosure", async () => {
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
  const job = await bridge.request({
    ...f.payload,
    since: now - 86400,
    until: now,
  });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(
    relayRequest(
      bridge,
      job.requestId,
      "https://relay.example.com",
      "route",
      controller.signal,
    ),
    /cancelled/,
  );
  assert.equal(
    (await bridge.status(job.requestId)).status,
    "pending_device_review",
  );
});
