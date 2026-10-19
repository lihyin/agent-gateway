import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import { build } from "esbuild";
import { Miniflare } from "miniflare";
import { Bridge } from "../../agent-adapter/src/bridge.js";
import { signObject, publicIdentity } from "../../agent-adapter/src/crypto.js";
import type { Pair } from "../src/direct.js";
import {
  registryPair,
  type RegistryEnvironment,
} from "../src/registry.js";

const f = JSON.parse(
  readFileSync(
    new URL("../../protocol/fixtures/pairing.json", import.meta.url),
    "utf8",
  ),
);
const origin = "https://relay.example.com";

test(
  "pairing self-registration stores a device-signed record and fails closed on a forged proof",
  { timeout: 60000 },
  async () => {
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
    const record = (await bridge.transportConfiguration()) as unknown as Pair;
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
        PAIRINGS: { className: "PairingChannel", useSQLite: true },
        PAIRINGS_REGISTRY: { className: "PairingRegistry", useSQLite: true },
      },
      bindings: { RELAY_ORIGIN: origin },
    });
    const connect = (session: string, role: string) =>
      mf.dispatchFetch(`${origin}/v1/pairing/${session}/${role}`, {
        headers: { Upgrade: "websocket" },
      });
    const payload = {
      version: 1,
      audience: origin,
      deviceId: record.deviceId,
      agentId: record.agentId,
      pairingEpoch: record.pairingEpoch,
      issuedAt: now,
      expiresAt: now + 300,
    };
    try {
      // Happy path: the phone presents its record mid-pairing; the relay
      // consumes the frame (the agent never sees it) and stores the record.
      const device = (await connect("b".repeat(64), "device")).webSocket!;
      device.accept();
      const agent = (await connect("b".repeat(64), "agent")).webSocket!;
      agent.accept();
      const forwarded = new Promise<string>((resolve) =>
        agent.addEventListener(
          "message",
          (event) => resolve(event.data as string),
          { once: true },
        ),
      );
      device.send(
        JSON.stringify({
          kind: "pairing_record",
          record,
          proof: await signObject(f.device, payload, "agw+pair-register"),
        }),
      );
      assert.equal(
        await Promise.race([
          forwarded,
          new Promise((resolve) => setTimeout(() => resolve("none"), 750)),
        ]),
        "none",
      );
      const env = {
        PAIRINGS_REGISTRY: await mf.getDurableObjectNamespace(
          "PAIRINGS_REGISTRY",
        ),
      } as unknown as RegistryEnvironment;
      let stored: unknown;
      for (let attempt = 0; attempt < 50 && !stored; attempt++) {
        stored = await registryPair(env, { agentId: record.agentId });
        if (!stored) await new Promise((r) => setTimeout(r, 100));
      }
      assert.deepEqual(stored, record);
      device.close();
      agent.close();

      // Forged proof (signed by the agent key, not the device key) fails
      // the session closed and stores nothing new.
      const device2 = (await connect("c".repeat(64), "device")).webSocket!;
      device2.accept();
      const agent2 = (await connect("c".repeat(64), "agent")).webSocket!;
      agent2.accept();
      const closed = new Promise<void>((resolve) =>
        device2.addEventListener("close", () => resolve(), { once: true }),
      );
      device2.send(
        JSON.stringify({
          kind: "pairing_record",
          record: { ...record, pairingEpoch: "forged-epoch" },
          proof: await signObject(f.agent, payload, "agw+pair-register"),
        }),
      );
      await Promise.race([
        closed,
        new Promise((_, reject) =>
          setTimeout(() => reject(new Error("session did not close")), 5000),
        ),
      ]);
      assert.deepEqual(await registryPair(env, { agentId: record.agentId }), record);
    } finally {
      await mf.dispose();
    }
  },
);
