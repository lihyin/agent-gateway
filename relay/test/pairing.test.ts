import assert from "node:assert/strict";
import test from "node:test";
import { build } from "esbuild";
import { Miniflare } from "miniflare";

test(
  "pairing channel joins once, forwards bounded live records and fails closed",
  { timeout: 60000 },
  async () => {
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
    const origin = "https://relay.example.com";
    const mf = new Miniflare({
      modules: true,
      script: bundle.outputFiles[0].text,
      compatibilityDate: "2026-08-06",
      durableObjects: {
        PAIRINGS: { className: "PairingChannel", useSQLite: true },
      },
      bindings: { RELAY_ORIGIN: origin },
    });
    const endpoint = `${origin}/v1/pairing/${"a".repeat(64)}`;
    const connect = (role: string) =>
      mf.dispatchFetch(`${endpoint}/${role}`, {
        headers: { Upgrade: "websocket" },
      });
    try {
      assert.equal((await connect("agent")).status, 409);
      assert.equal(
        (
          await mf.dispatchFetch(`${endpoint}/device?pin=12345678`, {
            headers: { Upgrade: "websocket" },
          })
        ).status,
        400,
      );
      assert.equal(
        (
          await mf.dispatchFetch(`${endpoint}/device`, {
            headers: { Upgrade: "websocket", Origin: origin },
          })
        ).status,
        400,
      );
      const device = (await connect("device")).webSocket!;
      device.accept();
      assert.equal((await connect("device")).status, 409);
      const next = (socket: typeof device) =>
        new Promise<string>((resolve) =>
          socket.addEventListener(
            "message",
            (event) => resolve(event.data as string),
            { once: true },
          ),
        );
      const joined = next(device);
      const agent = (await connect("agent")).webSocket!;
      agent.accept();
      assert.equal(JSON.parse(await joined).kind, "joined");
      assert.equal((await connect("agent")).status, 409);
      const challenge = next(agent);
      device.send('{"kind":"challenge"}');
      assert.equal(await challenge, '{"kind":"challenge"}');
      const proof = next(device);
      agent.send('{"kind":"proof"}');
      assert.equal(await proof, '{"kind":"proof"}');
      const closed = new Promise<void>((resolve) =>
        device.addEventListener("close", () => resolve(), { once: true }),
      );
      agent.send("x".repeat(8193));
      await closed;
      assert.equal((await connect("agent")).status, 409);
    } finally {
      await mf.dispose();
    }
  },
);
